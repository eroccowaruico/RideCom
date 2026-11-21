import CallControl
import CryptoKit
import Foundation
import RTC
import SessionManager
import Testing
import UserNotifications
@testable import RideIntercom

extension NotificationClientTests {
    @Test func foregroundArrivalOnlyChangesPresentationAndStaysQuietThroughoutACall() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture), model = harness.viewModel
        defer { model.disconnect() }
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        owner.notificationBridge.bind(to: owner)
        let tap = CallNotificationTap(requestID: UUID(), recipientID: fixture.local.userID)
        let initialRequestCount = NotificationHTTPStub.requests.count
        #expect(owner.notificationBridge.presentationOptions(for: tap) == [.banner, .list, .sound])
        #expect(harness.callSession.connectedGroup == nil && owner.callPresentationID == nil)
        #expect(model.createTalkGroup(name: "Current call", userIDs: [fixture.user.id]))
        #expect(model.hasAnyActiveGroupConnection && model.authenticatedPeerIDs.isEmpty)
        let reference = model.currentCallReference
        #expect(
            owner.notificationBridge.presentationOptions(for: tap) == [.list],
            "Waiting for peers is still an active call")
        model.setSoundIsolationEnabled(false)
        harness.callSession.authenticate(["friend"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(model.isAudioReady)
        #expect(owner.notificationBridge.presentationOptions(for: tap) == [.list])
        model.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: harness.audioSessionBackend.current)))
        #expect(model.isAudioPausedForDeviceChange && model.hasAnyActiveGroupConnection)
        #expect(owner.notificationBridge.presentationOptions(for: tap) == [.list])
        #expect(model.currentCallReference == reference && owner.callPresentationID == nil)
        #expect(NotificationHTTPStub.requests.count == initialRequestCount, "Arrival performs no network lookup")
        model.disconnect()
        #expect(owner.notificationBridge.presentationOptions(for: tap) == [.banner, .list, .sound])
    }

    @Test func foregroundPresentationRejectsMissingOwnerDisabledAndUnrelatedAccounts() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let harness = notificationHarness(fixture), model = harness.viewModel
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let tap = CallNotificationTap(requestID: UUID(), recipientID: fixture.local.userID)
        #expect(owner.notificationBridge.presentationOptions(for: tap).isEmpty)
        owner.notificationBridge.bind(to: owner)
        #expect(owner.notificationBridge.presentationOptions(for: tap).isEmpty)
        fixture.store.notificationRegistrationEnabled = true
        let wrongRecipient = CallNotificationTap(requestID: UUID(), recipientID: fixture.peer.userID)
        #expect(owner.notificationBridge.presentationOptions(for: wrongRecipient).isEmpty)
        let other = AppTestSupport.makeHarness()
        let mismatched = AppCallOwner(account: other.viewModel.accountSession, viewModel: model)
        mismatched.notificationBridge.bind(to: mismatched)
        #expect(mismatched.notificationBridge.presentationOptions(for: tap).isEmpty)
        let signedOut = AppTestSupport.signedInAccount()
        signedOut.signOut()
        let retired = AppTestSupport.makeHarness(accountSession: signedOut)
        retired.viewModel.notifications = fixture.notifications
        let retiredOwner = AppCallOwner(account: signedOut, viewModel: retired.viewModel)
        retiredOwner.notificationBridge.bind(to: retiredOwner)
        #expect(!retired.viewModel.hasCurrentAccountAccess)
        #expect(retiredOwner.notificationBridge.presentationOptions(for: tap).isEmpty)
        #expect(NotificationHTTPStub.requests.isEmpty && harness.callSession.connectedGroup == nil)
    }

    @Test func tapResolvesOnlyCurrentSavedSenderAndRejectsOldAccountOrDelayedExpiry() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let requestID = UUID(), tap = CallNotificationTap(requestID: requestID, recipientID: fixture.local.userID)
        let reply = CallNotificationReply(
            requestID: requestID, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        #expect(await fixture.notifications.resolveTap(tap) == fixture.user.id)
        fixture.now = fixture.now.addingTimeInterval(120)
        #expect(await fixture.notifications.resolveTap(tap) == nil)
        fixture.current = false
        let previous = NotificationHTTPStub.requests.count
        #expect(await fixture.notifications.resolveTap(tap) == nil)
        #expect(NotificationHTTPStub.requests.count == previous)
    }

    @Test func delayedTapCannotAffectAStoppedLogin() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(
            requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let resolving = Task {
            await fixture.notifications.resolveTap(.init(requestID: id, recipientID: fixture.local.userID))
        }
        await gate.waitForEntry()
        fixture.current = false
        NotificationHTTPStub.delayGate = nil
        let cleanup = fixture.notifications.stop()
        await gate.release()
        #expect(await resolving.value == nil)
        await cleanup?.value
        #expect(!fixture.notifications.receivesNotifications)
    }

    @Test func notificationTapUsesCommonCallActionButArrivalDoesNotStartAudio() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        #expect(harness.callSession.connectedGroup == nil)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(
            requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        owner.notificationBridge.bind(to: owner)
        #expect(await owner.notificationBridge.respond(to: .init(requestID: id, recipientID: fixture.local.userID),
            actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: ""))
        #expect(harness.callSession.connectedGroup?.kind == .direct && harness.viewModel.activeGroupID != nil)
        #expect(owner.callPresentationID != nil)
    }

    /// An old notice whose sender cannot be resolved opens your users without an error, and starts nothing.
    @Test func expiredNotificationOpensUsersWithoutAnError() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(
            requestID: id, expiresAt: fixture.now.addingTimeInterval(-1).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        owner.notificationBridge.bind(to: owner)
        #expect(!(await owner.notificationBridge.respond(to: .init(requestID: id, recipientID: fixture.local.userID),
            actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")))
        #expect(harness.callSession.connectedGroup == nil && owner.callPresentationID == nil)
        #expect(owner.usersPresentationID != nil)
        #expect(harness.viewModel.groupErrorMessage == nil)
    }

    @Test func expiredOrUnavailableNotificationOpensTheCurrentCallWithoutLookingUpTheSender() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        owner.notificationBridge.bind(to: owner)
        #expect(harness.viewModel.createTalkGroup(name: "Current call", userIDs: [fixture.user.id]))
        let groupID = try #require(harness.viewModel.regularGroups.first?.id)
        #expect(harness.viewModel.hasAnyActiveGroupConnection && harness.viewModel.authenticatedPeerIDs.isEmpty)
        let current = harness.viewModel.currentCallReference
        let before = NotificationHTTPStub.requests.count

        for status in [410, 503] {
            if status == 503 {
                harness.viewModel.setSoundIsolationEnabled(false)
                harness.callSession.authenticate(["friend"])
                await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
                #expect(harness.viewModel.isAudioReady)
                harness.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
                    reason: .routeChanged(.oldDeviceUnavailable), snapshot: harness.audioSessionBackend.current)))
                #expect(harness.viewModel.isAudioPausedForDeviceChange)
            }
            NotificationHTTPStub.status = status
            owner.callPresentationID = nil
            await owner.notificationBridge.respond(to: .init(requestID: UUID(), recipientID: fixture.local.userID),
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")
            #expect(owner.callPresentationID != nil)
            #expect(owner.usersPresentationID == nil)
            #expect(harness.viewModel.currentCallReference == current && harness.viewModel.selectedGroup?.id == groupID)
            #expect(harness.viewModel.groupErrorMessage == nil)
        }
        #expect(NotificationHTTPStub.requests.count == before)
    }

    @Test func callStartedDuringAnUnsuccessfulNotificationLookupTakesPriority() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        owner.notificationBridge.bind(to: owner)
        NotificationHTTPStub.status = 410
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        let responding = Task {
            await owner.notificationBridge.respond(to: .init(requestID: UUID(), recipientID: fixture.local.userID),
                actionIdentifier: "RIDEINTERCOM_CONNECT", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")
        }
        await gate.waitForEntry()
        #expect(harness.viewModel.createTalkGroup(name: "Started while looking up"))
        let groupID = harness.viewModel.regularGroups.first?.id
        let current = harness.viewModel.currentCallReference
        await gate.release()
        _ = await responding.value
        #expect(groupID != nil && current.groupID == groupID && harness.viewModel.hasAnyActiveGroupConnection)
        #expect(owner.callPresentationID != nil && owner.usersPresentationID == nil)
        #expect(harness.viewModel.currentCallReference == current && harness.viewModel.selectedGroup?.id == groupID)
    }

    @Test func notificationForAnotherRecipientDoesNotOpenAnyScreen() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        owner.notificationBridge.bind(to: owner)
        let before = NotificationHTTPStub.requests.count
        await owner.notificationBridge.respond(to: .init(requestID: UUID(), recipientID: fixture.peer.userID),
            actionIdentifier: UNNotificationDefaultActionIdentifier, categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")
        #expect(owner.callPresentationID == nil && owner.usersPresentationID == nil)
        #expect(NotificationHTTPStub.requests.count == before && harness.callSession.connectedGroup == nil)
    }

    @Test func delayedNotificationTapCannotStartAfterTheAppChangesItsModel() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID()
        let reply = CallNotificationReply(
            requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        let gate = ManualAsyncGate(); NotificationHTTPStub.delayGate = gate
        owner.notificationBridge.bind(to: owner)
        let responding = Task {
            await owner.notificationBridge.respond(
                to: .init(requestID: id, recipientID: fixture.local.userID),
            actionIdentifier: "RIDEINTERCOM_CONNECT", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST") }
        await gate.waitForEntry(); owner.viewModel = nil
        await gate.release()
        #expect(!(await responding.value))
        #expect(harness.callSession.connectedGroup == nil)
    }

    @Test func foregroundSuppressionSharesTheCurrentRecipientAndOnBoundaryWithTap() throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let tap = CallNotificationTap(requestID: UUID(), recipientID: fixture.local.userID)
        #expect(!fixture.notifications.canReceive(tap))
        fixture.store.notificationRegistrationEnabled = true
        #expect(fixture.notifications.canReceive(tap))
        #expect(!fixture.notifications.canReceive(.init(requestID: tap.requestID, recipientID: fixture.peer.userID)))
        fixture.current = false
        #expect(!fixture.notifications.canReceive(tap))
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    /// Connect opens the app (unlocking first), the same as tapping; Ignore only closes the notification.
    @Test func callRequestCategoryOffersConnectAndIgnore() throws {
        let category = NotificationSystem.callRequestCategory
        #expect(category.identifier == "RIDEINTERCOM_CALL_REQUEST")
        #expect(category.actions.map(\.identifier) == ["RIDEINTERCOM_CONNECT", "RIDEINTERCOM_IGNORE"])
        let connect = category.actions[0], ignore = category.actions[1]
        #expect(connect.options == [.foreground] && connect.title == String(localized: "Connect"))
        #expect(ignore.options.isEmpty && ignore.title == String(localized: "Ignore"))
        #expect(!ignore.options.contains(.destructive), "Ignoring is not a refusal")
    }

    @Test func backgroundResponseUsesTheCommonValidatedTapAndRejectsUnknownDismissAndWrongCategory() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        fixture.store.notificationRegistrationEnabled = true
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        let owner = AppCallOwner(account: harness.viewModel.accountSession, viewModel: harness.viewModel)
        owner.notificationBridge.bind(to: owner)
        let grant = try testCallNotificationGrant(owner: fixture.local, allowedSender: fixture.peer)
        try NotificationHTTPStub.setJSONResponse(grant)
        #expect(await fixture.notifications.setIncomingAllowed(true, contactID: fixture.user.id))
        let id = UUID(), tap = CallNotificationTap(requestID: id, recipientID: fixture.local.userID)
        let before = NotificationHTTPStub.requests.count
        for action in ["unrecognized", UNNotificationDismissActionIdentifier, "RIDEINTERCOM_IGNORE"] {
            #expect(
                !(await owner.notificationBridge.respond(
                    to: tap, actionIdentifier: action, categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")))
        }
        #expect(
            !(await owner.notificationBridge.respond(
                to: tap, actionIdentifier: "RIDEINTERCOM_CONNECT", categoryIdentifier: "other")))
        #expect(NotificationHTTPStub.requests.count == before && harness.callSession.connectedGroup == nil)
        let reply = CallNotificationReply(
            requestID: id, expiresAt: fixture.now.addingTimeInterval(120).timeIntervalSince1970 * 1000,
            status: .accepted, senderUserID: fixture.peer.userID)
        try NotificationHTTPStub.setJSONResponse(reply)
        #expect(
            await owner.notificationBridge.respond(
                to: tap, actionIdentifier: "RIDEINTERCOM_CONNECT", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST")
        )
        #expect(harness.callSession.connectedGroup?.kind == .direct)
        #expect(harness.viewModel.createTalkGroup(name: "Another call"))
        let groupID = try #require(harness.viewModel.regularGroups.first?.id)
        #expect(
            harness.viewModel.startCall(
                to: .group(groupID), accountAccessID: harness.viewModel.accountAccessID, allowSwitchingCall: true))
        let current = harness.viewModel.currentCallReference
        #expect(
            !(await owner.notificationBridge.respond(
                to: tap, actionIdentifier: "RIDEINTERCOM_CONNECT", categoryIdentifier: "RIDEINTERCOM_CALL_REQUEST"))
        )
        #expect(harness.viewModel.currentCallReference == current)
        // One place at a time: the notice only opens the live call, with no error.
        #expect(harness.viewModel.selectedGroup?.id == groupID && harness.viewModel.groupErrorMessage == nil)
    }

    /// A new one-to-one connection sends the call notification exactly once; reopening the live call does not
    /// send again, and nothing withdraws or follows it (an intercom: people join together).
    @Test func startingAOneToOneCallSendsTheNotificationOnceAndNeverFollowsUp() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let harness = notificationHarness(fixture); defer { harness.viewModel.disconnect() }
        try fixture.notifications.receivePermission(
            .make(
                owner: fixture.peer, allowedSender: fixture.local, revision: 1,
                grant: try testCallNotificationGrant(owner: fixture.peer, allowedSender: fixture.local),
                signer: fixture.peerSigner), peerID: "friend")
        NotificationHTTPStub.echoCallStatus = .accepted
        #expect(harness.viewModel.openDestination(.user(fixture.user.id)) == .opened)
        for _ in 0..<100 where NotificationHTTPStub.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(NotificationHTTPStub.requests.count == 1)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "POST")
        #expect(harness.viewModel.openDestination(.user(fixture.user.id)) == .opened)
        try await Task.sleep(for: .milliseconds(100))
        #expect(NotificationHTTPStub.requests.count == 1, "Reopening the live call does not send again")
        harness.viewModel.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(
            NotificationHTTPStub.requests.allSatisfy { $0.httpMethod != "DELETE" },
            "Nothing withdraws the notification")
    }
}
