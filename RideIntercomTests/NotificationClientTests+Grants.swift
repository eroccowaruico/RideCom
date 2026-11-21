import CallControl
import CryptoKit
import Foundation
import RTC
import SessionManager
import Testing
import UserNotifications
@testable import RideIntercom

extension NotificationClientTests {
    @Test func aGroupDeliveryPermissionCannotBeAddedOutsideThePeerSignature() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let value = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: nil, signer: fixture.peerSigner)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        fields["groupGrant"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(
                testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)))
        let injected = try JSONDecoder().decode(
            CallNotificationPermissionMessage.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try fixture.notifications.receivePermission(injected, peerID: "friend") }
    }

    @Test func groupDeliveryPermissionIsSeparateSignedPersistentAndRevocable() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(
            owner: fixture.peer, allowedSender: fixture.local, audience: "rideintercom-group-invitation")
        let value = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: nil, signer: fixture.peerSigner, groupGrant: grant, groupInvitationsSupported: true)
        try fixture.notifications.receivePermission(value, peerID: "friend")
        #expect(fixture.notifications.groupInvitationGrant(for: fixture.user.id) == grant)
        #expect(!fixture.notifications.canNotify(fixture.user.id))
        let oldPeer = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 2, grant: nil, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(oldPeer, peerID: "friend")
        #expect(fixture.notifications.groupInvitationGrant(for: fixture.user.id) == grant)
        let revoked = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 3,
            grant: nil, signer: fixture.peerSigner, groupInvitationsSupported: true)
        try fixture.notifications.receivePermission(revoked, peerID: "friend")
        try fixture.notifications.receivePermission(value, peerID: "friend")
        #expect(fixture.notifications.groupInvitationGrant(for: fixture.user.id) == nil)
    }

    @Test func explicitContactPermissionPersistsAndSignedRevocationCannotBeReplayed() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(fixture.notifications.allowsIncoming(from: fixture.user.id))
        #expect(try fixture.store.notificationPermissions().first?.receiving == grant)
        let sending = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
            signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(sending, peerID: "friend")
        #expect(fixture.notifications.canNotify(fixture.user.id))
        let revoked = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 2,
            grant: nil, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(revoked, peerID: "friend")
        try fixture.notifications.receivePermission(sending, peerID: "friend")
        #expect(!fixture.notifications.canNotify(fixture.user.id))
        #expect(try fixture.store.notificationPermissions().first?.receivedRevision == 2)
    }

    @Test func localRemovalBlocksTapBeforeServerRevocationCompletes() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        try fixture.notifications.suppressContact(fixture.user.id)
        #expect(!fixture.notifications.allowsIncoming(from: fixture.user.id))
        NotificationHTTPStub.status = 503
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.receiving?.grantID == grant.grantID)
        NotificationHTTPStub.status = 200; NotificationHTTPStub.setRawResponse("{}")
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.receiving == nil)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func verifiedContactMergeKeepsPermissionAndRemovalStillRevokesTheOriginalGrant() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let merged = SavedUser(displayName: "Same verified account", memberIDs: fixture.user.memberIDs,
            deviceKeys: fixture.user.deviceKeys, principal: fixture.peer)
        fixture.users = [merged]
        #expect(fixture.notifications.allowsIncoming(from: merged.id))
        NotificationHTTPStub.setRawResponse("{}")
        #expect(await fixture.notifications.setIncomingAllowed(false, contactID: merged.id))
        #expect(!fixture.notifications.allowsIncoming(from: merged.id))
        #expect(
            NotificationHTTPStub.requests.last?.url?.path == "/api/notifications/grants/"
                + grant.grantID.uuidString.lowercased())
    }

    @Test func regularGroupsNeverBroadcastOrAcceptPersonalNotificationGrants() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(harness.viewModel.createTalkGroup(name: "Regular", userIDs: [fixture.user.id]))
        #expect(
            harness.viewModel.startCall(
                to: .group(try #require(harness.viewModel.selectedGroup).id),
                accountAccessID: harness.viewModel.accountAccessID))
        try authenticateNotificationPeer(harness, fixture: fixture)
        harness.viewModel.sendNotificationPermissions()
        #expect(
            !harness.callSession.sentApplicationDataMessages.contains {
                $0.namespace == CallNotificationPermissionMessage.namespace
            })
        let incoming = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
            signer: fixture.peerSigner)
        harness.viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(incoming))))
        #expect(!fixture.notifications.canNotify(fixture.user.id))
    }

    @Test func onlyTheMatchingSinglePeerDirectCallExchangesNotificationPermission() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        #expect(
            harness.viewModel.startCall(
                to: .user(fixture.user.id), accountAccessID: harness.viewModel.accountAccessID))
        try authenticateNotificationPeer(harness, fixture: fixture)
        harness.viewModel.sendNotificationPermissions()
        #expect(
            harness.callSession.sentApplicationDataMessages.contains {
                $0.namespace == CallNotificationPermissionMessage.namespace
            })
        let incoming = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
            signer: fixture.peerSigner)
        harness.viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(incoming))))
        #expect(fixture.notifications.canNotify(fixture.user.id))
        let before = harness.callSession.sentApplicationDataMessages.count
        harness.viewModel.connectedPeerIDs.append("unrelated")
        harness.viewModel.authenticatedPeerIDs.append("unrelated")
        harness.viewModel.sendNotificationPermissions()
        #expect(harness.callSession.sentApplicationDataMessages.count == before)
    }

    @Test func aGrantWhoseLocalSaveFailsIsRevokedOnceInsteadOfLosingItsIdentifier() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        fixture.keychain.failWriteAccount = "notification-permissions"
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(!fixture.notifications.allowsIncoming(from: fixture.user.id))
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(
            NotificationHTTPStub.requests.last?.url?.path == "/api/notifications/grants/"
                + grant.grantID.uuidString.lowercased())
    }

    @Test func aKnownSecondDeviceHasItsOwnRevisionAndCannotRevokeAnotherDevicesGrant() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let second = try DeviceIdentitySigner(memberID: "friend-tablet", key: .init())
        fixture.users[0].memberIDs.append("friend-tablet")
        fixture.users[0].deviceKeys?["friend-tablet"] = second.publicKey
        let firstGrant = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let secondGrant = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let first = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 10, grant: firstGrant, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(first, peerID: "friend")
        let next = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: secondGrant, signer: second)
        try fixture.notifications.receivePermission(next, peerID: "friend-tablet")
        #expect(try fixture.store.notificationPermissions().first?.sending == secondGrant)
        let otherDeviceRevocation = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local,
            revision: 11, grant: nil, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(otherDeviceRevocation, peerID: "friend")
        #expect(try fixture.store.notificationPermissions().first?.sending == secondGrant)
        let revoked = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 2, grant: nil, signer: second)
        try fixture.notifications.receivePermission(revoked, peerID: "friend-tablet")
        try fixture.notifications.receivePermission(next, peerID: "friend-tablet")
        #expect(!fixture.notifications.canNotify(fixture.user.id))
    }

    @Test func aPeerCannotRedirectTheSelectedContactUsingAnotherRecipientsCapability() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let unrelated = AccountPrincipal(issuer: fixture.peer.issuer, userID: String(repeating: "f", count: 64))
        let otherGrant = try testCallNotificationGrant(owner: unrelated, allowedSender: fixture.local)
        let wrapped = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: otherGrant, signer: fixture.peerSigner)
        #expect(throws: (any Error).self) { try fixture.notifications.receivePermission(wrapped, peerID: "friend") }
        #expect(!fixture.notifications.canNotify(fixture.user.id) && NotificationHTTPStub.requests.isEmpty)
    }

    @Test func matchingUnverifiedClaimsStillRequireTheServersSignatureAndPermissionCheck() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let signed = try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local)
        let parts = signed.capability.split(separator: ".")
        let notServerVerified = CallNotificationGrant(
            grantID: signed.grantID, capability: parts[0] + "." + parts[1] + ".invalid-signature")
        let message = try CallNotificationPermissionMessage.make(owner: fixture.peer, allowedSender: fixture.local,
            revision: 1, grant: notServerVerified, signer: fixture.peerSigner)
        try fixture.notifications.receivePermission(message, peerID: "friend")
        NotificationHTTPStub.status = 403
        #expect(await fixture.notifications.send(to: fixture.user.id) == nil)
        #expect(NotificationHTTPStub.requests.count == 1)
    }

    @Test func cancelledRemovedContactsReleaseAll256SlotsBeforeGrantingANewPerson() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let records = (1...256).map { number in
            CallNotificationPermission(contactID: UUID(), owner: fixture.local,
                peer: .init(issuer: fixture.local.issuer, userID: String(format: "%064x", number)),
                revision: UInt64(number))
        }
        try fixture.store.saveNotificationPermissions(records)
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(NotificationHTTPStub.requests.isEmpty)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let saved = try #require(fixture.store.notificationPermissions().first)
        #expect(saved.receiving == grant && saved.revision > 256)
    }

    @Test func readdingTheSamePersonKeepsIssuedRevisionAboveThePrunedRecordAcrossReload() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let user = fixture.user
        try fixture.store.saveNotificationPermissions([
            .init(contactID: user.id, owner: fixture.local, peer: fixture.peer, revision: 40)
        ])
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().count == 1) // Keep a saved contact's revocation.
        try fixture.notifications.suppressContact(user.id)
        let lastRevision = try #require(fixture.store.notificationPermissions().first?.revision)
        #expect(lastRevision > 40)
        fixture.users = []
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
        fixture.users = [user]
        let restartedStore = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        let restarted = CallNotifications(store: restartedStore, memberID: "local", client: fixture.client,
            isCurrentUser: { fixture.current }, contacts: { fixture.users })
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await restarted.setIncomingAllowed(true, contactID: user.id))
        #expect(try restartedStore.notificationPermissions().first?.revision ?? 0 > lastRevision)
    }

    @Test func failedRevocationKeepsItsGrantWhileAlreadyCancelledRemovedRowsAreReclaimed() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let pending = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        let other = AccountPrincipal(issuer: fixture.local.issuer, userID: String(repeating: "f", count: 64))
        try fixture.store.saveNotificationPermissions([
            .init(
                contactID: fixture.user.id, owner: fixture.local, peer: fixture.peer, receiving: pending,
                revision: 7),
            .init(contactID: UUID(), owner: fixture.local, peer: other, revision: 8)
        ])
        fixture.users = []; NotificationHTTPStub.status = 503
        await fixture.notifications.retryRevocations()
        let saved = try fixture.store.notificationPermissions()
        #expect(saved.count == 1 && saved.first?.receiving == pending)
        #expect(NotificationHTTPStub.requests.count == 1)
    }

    @Test(arguments: ["-1", "+1", "broken", String(UInt64.max), String(UInt64.max - 1)])
    func invalidOrExhaustedRevisionCounterDoesNotPublishOrLoseANewGrant(counter: String) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        UserDefaults(suiteName: fixture.namespace)?.set(counter, forKey: "CallNotifications.issuedRevision")
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["POST", "DELETE"])
        #expect(NotificationHTTPStub.requests.last?.url?.lastPathComponent == grant.grantID.uuidString.lowercased())
    }

    @Test func failedCleanupSaveKeepsTheRecordInMemoryAndOnDiskForRetry() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let user = fixture.user
        try fixture.store.saveNotificationPermissions([
            .init(contactID: user.id, owner: fixture.local, peer: fixture.peer, revision: 400)
        ])
        fixture.users = []; fixture.keychain.failWriteAccount = "notification-permissions"
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().first?.revision == 400)
        fixture.users = [user]
        let signer = try fixture.store.invitationSigner(memberID: "local")
        #expect(try fixture.notifications.permissionMessage(for: "friend", signer: signer)?.revision == 400)
        fixture.users = []; fixture.keychain.failWriteAccount = nil
        await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
    }

    /// The notice is sent once and never followed up, so unrelated housekeeping must not swallow it.
    @Test func aNoticeIsStillSentWhileAReceivingGrantIsBeingIssued() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        try fixture.notifications.receivePermission(
            .make(
                owner: fixture.peer, allowedSender: fixture.local, revision: 1,
                grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
                signer: fixture.peerSigner), peerID: "friend")
        try NotificationHTTPStub.setJSONResponse(
            try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer))
        NotificationHTTPStub.echoCallStatus = .accepted
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let issuing = Task { await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id) }
        await gate.waitForEntry()
        NotificationHTTPStub.delayGate = nil
        #expect(fixture.notifications.isBusy)
        #expect(await fixture.notifications.send(to: fixture.user.id)?.status == .accepted)
        await gate.release()
        #expect(await issuing.value)
        #expect(fixture.notifications.allowsIncoming(from: fixture.user.id))
    }

    /// The first call should already be able to notify: the two permissions cross while the people
    /// are registering each other, without waiting for a first one-to-one connection.
    @Test func registeringSomeoneSharesThePermissionToNotifyOverTheInvitationExchange() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let exchange = RecordingCallSession()
        harness.viewModel.contactSessionFactory = { exchange }
        defer { harness.viewModel.stopContactInvitationSession() }
        try NotificationHTTPStub.setJSONResponse(
            try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer))
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let accepted = try token.accept(signer: fixture.peerSigner, displayName: "Friend", contactBootstrap: true)
        exchange.authenticate(["friend"])
        exchange.onEvent?(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: DirectInvitationReceipt.namespace,
            payload: try JSONEncoder().encode(accepted.receipt))))
        func shared() -> ApplicationDataMessage? {
            exchange.sentApplicationDataMessages.last { $0.namespace == CallNotificationPermissionMessage.namespace }
        }
        await AppTestSupport.waitUntil { shared() != nil }
        let mine = try JSONDecoder().decode(
            CallNotificationPermissionMessage.self, from: try #require(shared()).payload)
        #expect(mine.grant != nil && mine.owner == fixture.local && mine.allowedSender == fixture.peer)
        #expect(fixture.notifications.allowsIncoming(from: fixture.user.id))

        #expect(!fixture.notifications.canNotify(fixture.user.id))
        let theirs = try CallNotificationPermissionMessage.make(
            owner: fixture.peer, allowedSender: fixture.local, revision: 1,
            grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
            signer: fixture.peerSigner)
        exchange.authenticate(["friend", "stranger"])
        exchange.onEvent?(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(theirs))))
        #expect(!fixture.notifications.canNotify(fixture.user.id), "Not while anyone else is in the exchange")
        exchange.authenticate(["friend"])
        exchange.onEvent?(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: CallNotificationPermissionMessage.namespace,
            payload: try JSONEncoder().encode(theirs))))
        #expect(fixture.notifications.canNotify(fixture.user.id))
    }

    private func authenticateNotificationPeer(_ harness: AppTestSupport.Harness, fixture: NotificationModelFixture)
        throws {
        harness.callSession.authenticate(["friend"])
        let profile = try testPeerProfile(
            harness.viewModel, peerID: "friend", displayName: "Friend", signer: fixture.peerSigner)
        harness.viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "friend",
                message: .init(
                    namespace: SharedDisplayName.namespace,
            payload: try JSONEncoder().encode(profile))))
        #expect(harness.viewModel.peerProfiles["friend"]?.verified != nil)
    }
}
