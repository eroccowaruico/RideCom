import Foundation
import Testing
import UserNotifications
@testable import RideIntercom

extension NotificationClientTests {
    enum ChangeWhileAwaitingMicrophone: CaseIterable {
        case none, deniesMicrophone, expires, ends, revokesGrant, replacesGrant
        case disablesNotifications, reenablesNotifications
    }

    @Test(arguments: ChangeWhileAwaitingMicrophone.allCases)
    func tapRechecksPermissionAndExpiryBeforeStartingCall(change: ChangeWhileAwaitingMicrophone) async throws {
        let fixture = try NotificationModelFixture(client: makeClient())
        defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        try #require(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))

        let permission = ManualAsyncGate()
        var askedForMicrophone = false
        let harness = notificationHarness(fixture, requestMicrophoneAccess: {
            askedForMicrophone = true
            await permission.wait()
            return change != .deniesMicrophone
        })
        let model = harness.viewModel
        defer { model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        owner.notificationBridge.bind(to: owner)
        let tap = CallNotificationTap(requestID: UUID(), recipientID: fixture.local.userID)
        let expiresAt = fixture.now.addingTimeInterval(120)
        try NotificationHTTPStub.setJSONResponse(CallNotificationReply(
            requestID: tap.requestID, expiresAt: expiresAt.timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID))

        let answer = Task {
            await owner.notificationBridge.respond(
                to: tap, actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "")
        }
        await AppTestSupport.waitUntil { askedForMicrophone }
        #expect(askedForMicrophone)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(owner.callPresentationID == nil)
        switch change {
        case .none, .deniesMicrophone: break
        case .expires: fixture.now = expiresAt.addingTimeInterval(1)
        case .ends:
            fixture.now = expiresAt.addingTimeInterval(1)
            model.disconnect()
        case .revokesGrant, .replacesGrant:
            try await changeIncomingGrant(fixture, reissue: change == .replacesGrant)
        case .disablesNotifications, .reenablesNotifications:
            NotificationHTTPStub.setRawResponse("{}")
            await fixture.notifications.disable()
            if change == .reenablesNotifications { await fixture.notifications.start() }
        }
        await permission.release()
        #expect(await answer.value == (change == .none))
        #expect((harness.callSession.connectedGroup != nil) == (change == .none))
        #expect((owner.callPresentationID != nil) == (change == .none))
        #expect((owner.usersPresentationID != nil) == (change == .expires))
        #expect(model.showsCallMicrophonePermissionAlert == (change == .deniesMicrophone))
    }

    private func changeIncomingGrant(_ fixture: NotificationModelFixture, reissue: Bool) async throws {
        NotificationHTTPStub.setRawResponse("{}")
        #expect(await fixture.notifications.setIncomingAllowed(false, contactID: fixture.user.id))
        if reissue {
            let replacement = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
            try NotificationHTTPStub.setJSONResponse(replacement)
            #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        }
    }

    @Test func deniedOrRetiredPermissionRequestsNeverRegisterAPNs() async throws {
        let fixture = try NotificationModelFixture(client: makeClient())
        fixture.permission = false
        await fixture.notifications.enable()
        #expect(fixture.registerCount == 0 && NotificationHTTPStub.requests.isEmpty)
        fixture.permission = true
        let gate = ManualAsyncGate(); fixture.authorizationGate = gate
        let enabling = Task { await fixture.notifications.enable() }
        await gate.waitForEntry()
        fixture.current = false; let cleanup = fixture.notifications.stop()
        await gate.release(); await enabling.value; await cleanup?.value
        #expect(fixture.registerCount == 0 && !fixture.notifications.receivesNotifications)
        fixture.remove()
    }

    /// No switch in the app: once the OS allows notifications, starting registers this device and lets every
    /// saved person notify you. When the OS turns them off, starting again removes the registration.
    @Test func startFollowsTheOSAndAllowsEverySavedPerson() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        await fixture.notifications.start()
        #expect(fixture.notifications.isEnabled && fixture.registerCount == 1)
        #expect(fixture.notifications.allowsIncoming(from: fixture.user.id), "Everyone you registered may notify you")
        await fixture.notifications.start()
        #expect(
            NotificationHTTPStub.requests.filter { $0.url?.path == "/api/notifications/grants" }.count == 1,
            "An existing call grant is not issued again; inbox permission may retry separately")
        fixture.permission = false
        await fixture.notifications.start()
        #expect(
            !fixture.notifications.isEnabled && fixture.unregisterCount == 1
                && fixture.notifications.authorizationDenied)
    }

    @Test func startNeverRegistersWithoutTheOSPermission() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.permission = false
        await fixture.notifications.start()
        #expect(!fixture.notifications.isEnabled && fixture.registerCount == 0)
        #expect(
            !fixture.notifications.allowsIncoming(from: fixture.user.id)
                && NotificationHTTPStub.requests.allSatisfy {
                    $0.url?.path == "/api/notifications/group-invitations/grants" || $0.httpMethod == "DELETE"
                })
    }

    @Test func lateDeviceRegistrationCannotMarkANewLoginReady() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        #expect(fixture.registerCount == 1)
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let registering = Task {
            await fixture.notifications.receivedDeviceToken(
                Data([1, 2, 3]), environment: "sandbox", topic: "fixture.app")
        }
        await gate.waitForEntry()
        fixture.current = false; NotificationHTTPStub.delayGate = nil
        let cleanup = fixture.notifications.stop()
        await gate.release(); await registering.value; await cleanup?.value
        #expect(!fixture.notifications.receivesNotifications)
    }

    @Test func unreadablePermissionsArePreservedAndCanBeCheckedAgain() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        try fixture.keychain.saveSecret(
            "unreadable permissions", service: fixture.namespace + ".InternetConnection",
            account: "notification-permissions")
        #expect(!fixture.notifications.canUseNotifications)
        #expect(
            try fixture.keychain.secret(
                service: fixture.namespace + ".InternetConnection", account: "notification-permissions")
                == "unreadable permissions")
        try fixture.keychain.saveSecret(
            "[]", service: fixture.namespace + ".InternetConnection", account: "notification-permissions")
        await fixture.notifications.refresh()
        #expect(fixture.notifications.canUseNotifications)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func notificationPermissionDenialIsDistinctFromRegistrationFailure() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.permission = false
        await fixture.notifications.enable()
        #expect(fixture.notifications.authorizationDenied)
        #expect(!fixture.notifications.isEnabled)
        fixture.permission = true
        await fixture.notifications.refresh()
        #expect(!fixture.notifications.authorizationDenied)
        #expect(!fixture.notifications.isEnabled)
        #expect(fixture.registerCount == 0)
        await fixture.notifications.enable()
        #expect(!fixture.notifications.authorizationDenied)
        #expect(fixture.notifications.isEnabled)
        #expect(fixture.registerCount == 1)
    }

    @Test func missingServiceCredentialsStillAllowLocalDisableAndUnregister() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        #expect(fixture.notifications.isEnabled && fixture.registerCount == 1)
        _ = try fixture.store.retireAppleCredential()
        #expect(!fixture.notifications.canRegisterNotifications)
        await fixture.notifications.disable()
        #expect(!fixture.notifications.isEnabled && !fixture.notifications.receivesNotifications)
        #expect(fixture.store.notificationRemovalPending && fixture.unregisterCount == 1)
        #expect(!fixture.notifications.canReceive(.init(requestID: UUID(), recipientID: fixture.local.userID)))
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func disabledDeviceRejectsTapsAndRetriesFailedServerRemoval() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        NotificationHTTPStub.status = 503
        await fixture.notifications.disable()
        #expect(!fixture.notifications.isEnabled && fixture.store.notificationRemovalPending)
        let previous = NotificationHTTPStub.requests.count
        #expect(
            await fixture.notifications.resolveTap(.init(requestID: UUID(), recipientID: fixture.local.userID))
                == nil)
        #expect(NotificationHTTPStub.requests.count == previous)
        NotificationHTTPStub.status = 200; NotificationHTTPStub.setRawResponse("{}")
        await fixture.notifications.refresh()
        #expect(NotificationHTTPStub.requests.count == previous + 1)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(!fixture.store.notificationRemovalPending && !fixture.notifications.receivesNotifications)
    }

    @Test func disablingDuringAPutRemovesTheDeviceAfterThatPutFinishes() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let registering = Task {
            await fixture.notifications.receivedDeviceToken(
                Data([1]), environment: "sandbox", topic: "fixture.app")
        }
        await gate.waitForEntry()
        let disabling = Task { await fixture.notifications.disable() }
        for _ in 0..<100 where fixture.notifications.isEnabled { await Task.yield() }
        #expect(!fixture.notifications.isEnabled)
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.isEmpty)
        NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.setRawResponse("{}")
        await gate.release(); await registering.value; await disabling.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(!fixture.notifications.receivesNotifications && !fixture.store.notificationRemovalPending)
    }

    @Test func reenablingBeforeAnOldCleanupCannotDeleteTheNewRegistration() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let old = Task {
            await fixture.notifications.receivedDeviceToken(
                Data([1]), environment: "sandbox", topic: "fixture.app")
        }
        await gate.waitForEntry()
        let disabling = Task { await fixture.notifications.disable() }
        for _ in 0..<100 where fixture.notifications.isEnabled { await Task.yield() }
        await fixture.notifications.enable()
        NotificationHTTPStub.delayGate = nil
        let fresh = Task {
            await fixture.notifications.receivedDeviceToken(
                Data([2]), environment: "sandbox", topic: "fixture.app")
        }
        await gate.release(); await old.value; await disabling.value; await fresh.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT", "PUT"])
        #expect(fixture.notifications.receivesNotifications && fixture.notifications.isEnabled)
        #expect(!fixture.store.notificationRemovalPending)
    }

    @Test func aDeleteAlreadyInFlightFinishesBeforeANewRegistration() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        await fixture.notifications.enable()
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "fixture.app")
        NotificationHTTPStub.requests = []; NotificationHTTPStub.setRawResponse("{}")
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let disabling = Task { await fixture.notifications.disable() }
        await gate.waitForEntry()
        await fixture.notifications.enable()
        NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        let registering = Task {
            await fixture.notifications.receivedDeviceToken(
                Data([2]), environment: "sandbox", topic: "fixture.app")
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])
        await gate.release(); await disabling.value; await registering.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE", "PUT"])
        #expect(fixture.notifications.receivesNotifications && !fixture.store.notificationRemovalPending)
    }

    @Test func groupInboxPermissionCanBeIssuedWithoutOSAlertPermissionAndRemovedWithTheContact() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.permission = false
        let grant = try testCallNotificationGrant(
            owner: fixture.local, allowedSender: fixture.peer, audience: "rideintercom-group-invitation")
        try NotificationHTTPStub.setJSONResponse(grant)
        await fixture.notifications.start()
        #expect(!fixture.notifications.isEnabled && fixture.registerCount == 0)
        #expect(try fixture.store.notificationPermissions().first?.groupReceiving == grant)
        #expect(NotificationHTTPStub.requests.first?.url?.path == "/api/notifications/group-invitations/grants")
        let signer = try fixture.store.invitationSigner(memberID: "local")
        let legacy = try #require(try fixture.notifications.permissionMessage(for: "friend", signer: signer))
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect(fields["groupGrant"] == nil && fields["groupInvitationsSupported"] == nil)
        let group = try #require(try fixture.notifications.groupPermissionMessage(for: "friend", signer: signer))
        #expect(group.groupGrant == grant && group.groupInvitationsSupported == true)
        try fixture.notifications.suppressContact(fixture.user.id); fixture.users = []
        NotificationHTTPStub.setRawResponse("{}"); await fixture.notifications.retryRevocations()
        #expect(try fixture.store.notificationPermissions().isEmpty)
        #expect(
            NotificationHTTPStub.requests.last?.url?.path == "/api/notifications/grants/"
                + grant.grantID.uuidString.lowercased())
    }

    @Test func unknownOrGroupOnlyContactsNeverIssueOrSendNotifications() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: UUID())))
        fixture.users = [SavedUser(id: fixture.user.id, displayName: "Group only", memberIDs: ["friend"])]
        #expect(!(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id)))
        #expect(await fixture.notifications.send(to: fixture.user.id) == nil)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }
}
