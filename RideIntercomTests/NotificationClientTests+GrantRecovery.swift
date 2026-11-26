import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension NotificationClientTests {
    enum OverlappingGrantOutcome: CaseIterable {
        case issued, groupUnavailable, callUnavailable
    }

    @Test(.timeLimit(.minutes(1)), arguments: OverlappingGrantOutcome.allCases)
    func registrationWaitsForAnExistingGroupGrant(outcome: OverlappingGrantOutcome) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.permission = false
        let harness = notificationHarness(fixture)
        let exchange = RecordingCallSession()
        harness.viewModel.contactSessionFactory = { exchange }
        defer { harness.viewModel.stopContactInvitationSession() }
        let firstSucceeds = outcome != .groupUnavailable
        let callFails = outcome == .callUnavailable
        let group = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer,
                                                 audience: "rideintercom-group-invitation")
        if !callFails {
            let call = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
            try NotificationHTTPStub.setJSONResponse(call)
            try #require(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        }
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let accepted = try token.accept(signer: fixture.peerSigner, displayName: "Friend", contactBootstrap: true)
        let receipt = try JSONEncoder().encode(accepted.receipt)

        try NotificationHTTPStub.setJSONResponse(group)
        NotificationHTTPStub.status = firstSucceeds ? 200 : 503
        let gate = ManualAsyncGate()
        NotificationHTTPStub.delayGate = gate
        let initial = Task { await fixture.notifications.start() }
        await gate.waitForEntry()
        NotificationHTTPStub.delayGate = nil
        NotificationHTTPStub.status = callFails ? 503 : 200

        exchange.authenticate(["friend"])
        exchange.onEvent?(.receivedApplicationData(peerID: "friend",
            message: .init(namespace: DirectInvitationReceipt.namespace, payload: receipt)))
        await AppTestSupport.waitUntil(timeout: .milliseconds(200)) {
            self.groupGrantRequestCount > 1 || self.sharedGroupPermission(in: exchange) != nil
        }
        #expect(groupGrantRequestCount == 1)
        #expect(sharedGroupPermission(in: exchange) == nil)
        await gate.release()
        await initial.value
        await AppTestSupport.waitUntil { self.sharedGroupPermission(in: exchange) != nil }
        let shared = try JSONDecoder().decode(
            CallNotificationPermissionMessage.self, from: try #require(sharedGroupPermission(in: exchange)).payload)
        #expect(shared.groupGrant == (firstSucceeds ? group : nil))
        #expect(!callFails || shared.grant == nil)
        #expect(try fixture.store.notificationPermissions().first?.revision == (firstSucceeds && !callFails ? 2 : 1))
        #expect(!callFails || NotificationHTTPStub.requests.contains { $0.url?.path == "/api/notifications/grants" })

        NotificationHTTPStub.status = 200
        await fixture.notifications.start()
        #expect(groupGrantRequestCount == (firstSucceeds ? 1 : 2))
        #expect(try fixture.store.notificationPermissions().first?.groupReceiving == group)
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherContactCanReceiveAGroupGrantWhileTheFirstIsPending() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.permission = false
        let first = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer,
                                                 audience: "rideintercom-group-invitation")
        let another = AccountPrincipal(issuer: fixture.peer.issuer, userID: String(repeating: "f", count: 64))
        let second = try testCallNotificationGrant(owner: fixture.local, allowedSender: another,
                                                  audience: "rideintercom-group-invitation")
        let newcomer = SavedUser(displayName: "Another rider", memberIDs: ["another"],
                                 deviceKeys: ["another": fixture.peerSigner.publicKey], principal: another)
        try NotificationHTTPStub.setJSONResponse(first)
        let gate = ManualAsyncGate()
        NotificationHTTPStub.delayGate = gate
        let initial = Task { await fixture.notifications.start() }
        await gate.waitForEntry()
        NotificationHTTPStub.delayGate = nil
        fixture.users.append(newcomer)
        try NotificationHTTPStub.setJSONResponse(second)
        let refresh = Task { await fixture.notifications.start() }
        await AppTestSupport.waitUntil {
            (try? fixture.store.notificationPermissions().contains { $0.groupReceiving == second }) == true
        }
        #expect(try fixture.store.notificationPermissions().compactMap(\.groupReceiving) == [second])
        await gate.release()
        await initial.value
        await refresh.value
        #expect(try fixture.store.notificationPermissions().compactMap(\.groupReceiving).count == 2)
        #expect(groupGrantRequestCount == 2)
    }

    private var groupGrantRequestCount: Int {
        NotificationHTTPStub.requests.count { $0.url?.path == "/api/notifications/group-invitations/grants" }
    }

    private func sharedGroupPermission(in exchange: RecordingCallSession) -> ApplicationDataMessage? {
        exchange.sentApplicationDataMessages.last { $0.namespace == CallNotificationPermissionMessage.groupNamespace }
    }

    @Test(arguments: [true, false])
    func deletingContactRevokesBothGrantsWhileInternetCallingIsOff(startsOnline: Bool) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        let call = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        let group = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer,
                                                 audience: "rideintercom-group-invitation")
        let contact = fixture.user.id
        try NotificationHTTPStub.setJSONResponse(call)
        try #require(await fixture.notifications.setIncomingAllowed(true, contactID: contact))
        try NotificationHTTPStub.setJSONResponse(group)
        await fixture.notifications.allowGroupInvitations()
        try #require(try fixture.store.notificationPermissions().first?.groupReceiving == group)
        NotificationHTTPStub.requests = []
        NotificationHTTPStub.setRawResponse("{}")
        model.setRTCTransportRoute(.webRTC, enabled: false)
        model.networkPathIsAvailable = startsOnline

        try #require(model.removeSavedUser(contact))
        #expect(model.savedRemoteUsers.isEmpty)
        fixture.users = model.savedRemoteUsers
        if !startsOnline {
            await fixture.notifications.retryRevocations()
            let pending = try #require(try fixture.store.notificationPermissions().first)
            #expect(!pending.allowsIncoming && pending.allowsGroupInvitations == false)
            #expect(pending.receiving == call && pending.groupReceiving == group)
            #expect(NotificationHTTPStub.requests.isEmpty)
            model.groupDeliveryNetworkPathChanged(isAvailable: true)
        }
        await AppTestSupport.waitUntil { (try? fixture.store.notificationPermissions().isEmpty) == true }

        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE", "DELETE"])
        let revokedIDs = NotificationHTTPStub.requests.compactMap { request in
            request.url.flatMap { UUID(uuidString: $0.lastPathComponent) }
        }
        #expect(revokedIDs == [call.grantID, group.grantID])
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(!model.enabledRTCTransportRoutes.contains(.webRTC))
    }

    @Test func savedGrantRevocationsWaitForInternetAndResumeForBothPurposes() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        let call = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        let group = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer,
                                                 audience: "rideintercom-group-invitation")
        try NotificationHTTPStub.setJSONResponse(call)
        try #require(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        try NotificationHTTPStub.setJSONResponse(group)
        await fixture.notifications.allowGroupInvitations()
        model.setRTCTransportRoute(.webRTC, enabled: false)
        try fixture.notifications.suppressContact(fixture.user.id)
        fixture.users = []
        NotificationHTTPStub.setRawResponse("{}")
        await fixture.notifications.retryRevocations()

        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.isEmpty)
        #expect(try fixture.store.notificationPermissions().first?.receiving == call)
        #expect(try fixture.store.notificationPermissions().first?.groupReceiving == group)
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.setRTCTransportRoute(.webRTC, enabled: true)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        await AppTestSupport.waitUntil { (try? fixture.store.notificationPermissions().isEmpty) == true }

        let revokedIDs = NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }
            .compactMap { $0.url.flatMap { UUID(uuidString: $0.lastPathComponent) } }
        #expect(revokedIDs == [call.grantID, group.grantID])
        #expect(try fixture.store.notificationPermissions().isEmpty)
    }

    enum RevocationInterruption: CaseIterable {
        case networkLost, settingOffWithUnknownPath, settingOffWithAvailablePath
    }

    @Test(arguments: RevocationInterruption.allCases)
    func interruptedInternetPreservesOrCancelsSavedGrantRevocation(
        interruption: RevocationInterruption
    ) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        try #require(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        try fixture.notifications.suppressContact(fixture.user.id)
        fixture.users = []
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        NotificationHTTPStub.setRawResponse("{}")
        let revoking = Task { await fixture.notifications.retryRevocations() }
        await gate.waitForEntry()
        switch interruption {
        case .networkLost:
            model.groupDeliveryNetworkPathChanged(isAvailable: false)
        case .settingOffWithUnknownPath:
            model.setRTCTransportRoute(.webRTC, enabled: false)
        case .settingOffWithAvailablePath:
            model.networkPathIsAvailable = true
            model.setRTCTransportRoute(.webRTC, enabled: false)
        }
        let shouldCancel = interruption != .settingOffWithAvailablePath
        if shouldCancel {
            await AppTestSupport.waitUntil {
                NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) }
            }
        }
        #expect(NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) } == shouldCancel)
        NotificationHTTPStub.delayGate = nil
        await gate.release(); await revoking.value

        if shouldCancel {
            #expect(try fixture.store.notificationPermissions().first?.receiving == grant)
            if interruption == .networkLost {
                model.groupDeliveryNetworkPathChanged(isAvailable: true)
            } else {
                model.setRTCTransportRoute(.webRTC, enabled: true)
            }
            await AppTestSupport.waitUntil { (try? fixture.store.notificationPermissions().isEmpty) == true }
        }
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.count == (shouldCancel ? 2 : 1))
        #expect(try fixture.store.notificationPermissions().isEmpty)
    }

    @Test(arguments: [false, true])
    func aReaddedContactWaitsForItsSavedRevocation(startsOnline: Bool) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        try #require(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let readded = fixture.user
        try fixture.notifications.suppressContact(readded.id)
        fixture.users = [readded]
        NotificationHTTPStub.setRawResponse("{}")

        if startsOnline {
            model.networkPathIsAvailable = true
            let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
            let restoring = Task { await fixture.notifications.setIncomingAllowed(true, contactID: readded.id) }
            await gate.waitForEntry()
            model.setRTCTransportRoute(.webRTC, enabled: false)
            await AppTestSupport.waitUntil {
                NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) }
            }
            #expect(NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) })
            NotificationHTTPStub.delayGate = nil
            await gate.release()
            #expect(!(await restoring.value))
        } else {
            model.setRTCTransportRoute(.webRTC, enabled: false)
            #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: readded.id)))
        }
        #expect(try fixture.store.notificationPermissions().first?.receiving == grant)
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.count == (startsOnline ? 1 : 0))

        model.setRTCTransportRoute(.webRTC, enabled: true)
        await AppTestSupport.waitUntil { (try? fixture.store.notificationPermissions().first?.receiving) == nil }
        #expect(try fixture.store.notificationPermissions().first?.receiving == nil)
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.count == (startsOnline ? 2 : 1))
    }
}
