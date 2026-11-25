import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension NotificationClientTests {
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

    @Test(arguments: [false, true])
    func interruptedInternetCancelsAnInFlightSavedGrantRevocation(disablesSetting: Bool) async throws {
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
        if disablesSetting {
            model.setRTCTransportRoute(.webRTC, enabled: false)
        } else {
            model.groupDeliveryNetworkPathChanged(isAvailable: false)
        }
        await AppTestSupport.waitUntil {
            NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) }
        }
        #expect(NotificationHTTPStub.cancelledRequests.withLock { $0.contains(grant.grantID) })
        NotificationHTTPStub.delayGate = nil
        await gate.release(); await revoking.value
        #expect(try fixture.store.notificationPermissions().first?.receiving == grant)

        if disablesSetting {
            model.setRTCTransportRoute(.webRTC, enabled: true)
        } else {
            model.groupDeliveryNetworkPathChanged(isAvailable: true)
        }
        await AppTestSupport.waitUntil { (try? fixture.store.notificationPermissions().isEmpty) == true }
        #expect(NotificationHTTPStub.requests.filter { $0.httpMethod == "DELETE" }.count == 2)
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
