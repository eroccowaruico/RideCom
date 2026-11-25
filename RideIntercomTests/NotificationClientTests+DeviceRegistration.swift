import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension NotificationClientTests {
    @Test(arguments: [false, true], [false, true])
    func deviceOperationCancelsAndResumes(removing: Bool, disablesSetting: Bool) async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        await fixture.notifications.enable()
        let gate = ManualAsyncGate()
        NotificationHTTPStub.delayGate = gate
        NotificationHTTPStub.setRawResponse(removing ? "{}" : "{\"registered\":true}")
        fixture.permission = !removing
        let methods = removing ? "DELETE" : "PUT"
        let first = Task {
            if removing {
                await fixture.notifications.disable()
            } else {
                await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "app")
            }
        }
        await gate.waitForEntry()
        if disablesSetting {
            model.setRTCTransportRoute(.webRTC, enabled: false)
        } else {
            model.groupDeliveryNetworkPathChanged(isAvailable: false)
        }
        await AppTestSupport.waitUntil { NotificationHTTPStub.cancelledDeviceMethods.withLock { $0.contains(methods) } }
        #expect(NotificationHTTPStub.cancelledDeviceMethods.withLock { $0.contains(methods) })
        NotificationHTTPStub.delayGate = nil
        await gate.release()
        await first.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == [methods])
        #expect(!fixture.notifications.receivesNotifications)
        #expect(fixture.notifications.removalPending == removing)

        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.setRTCTransportRoute(.webRTC, enabled: true)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        if removing {
            await AppTestSupport.waitUntil { !fixture.notifications.removalPending }
        } else {
            await AppTestSupport.waitUntil { fixture.registerCount == 2 }
            #expect(fixture.registerCount == 2)
            await fixture.notifications.receivedDeviceToken(Data([2]), environment: "sandbox", topic: "app")
        }
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == [methods, methods])
        #expect(!fixture.notifications.removalPending && fixture.notifications.receivesNotifications == !removing)
    }

    @Test func removalAndSignOutWhileInternetIsOffSendNoDeviceRequest() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        await fixture.notifications.enable()
        model.setRTCTransportRoute(.webRTC, enabled: false)
        fixture.permission = false
        NotificationHTTPStub.setRawResponse("{}")
        await fixture.notifications.disable()
        await fixture.notifications.stop()?.value
        #expect(fixture.notifications.removalPending && !fixture.notifications.isEnabled)
        #expect(NotificationHTTPStub.requests.isEmpty)
    }

    @Test func onlineSignOutStillRemovesTheDeviceAfterReleasingItsModel() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        var model: IntercomViewModel? = notificationHarness(fixture).viewModel
        let owner = try #require(model.map { AppCallOwner(account: $0.accountSession, viewModel: $0) })
        weak var retired = model
        model = nil
        await fixture.notifications.enable()
        NotificationHTTPStub.setRawResponse("{}")
        // Exercise the app owner's retirement path without the separate account revocation request.
        owner.account.onAccessRevoked = nil
        owner.account.signOut()
        await AppTestSupport.waitUntil { retired == nil && !NotificationHTTPStub.requests.isEmpty }
        #expect(owner.viewModel == nil && retired == nil)
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])
    }

    @Test func disablingInternetDropsTheQueuedDeleteAndRetriesOnlyAfterRecovery() async throws {
        let fixture = try NotificationModelFixture(client: makeClient()); defer { fixture.remove() }
        let model = notificationHarness(fixture).viewModel
        await fixture.notifications.enable()
        let gate = ManualAsyncGate()
        NotificationHTTPStub.delayGate = gate
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        let registering = Task {
            await fixture.notifications.receivedDeviceToken(Data([1]), environment: "sandbox", topic: "app")
        }
        await gate.waitForEntry()
        fixture.permission = false
        let removing = Task { await fixture.notifications.disable() }
        await AppTestSupport.waitUntil { fixture.notifications.deviceOperations.count == 2 }
        #expect(fixture.notifications.deviceOperations.count == 2)
        model.setRTCTransportRoute(.webRTC, enabled: false)

        NotificationHTTPStub.delayGate = nil
        NotificationHTTPStub.setRawResponse("{}")
        await gate.release()
        await registering.value
        await removing.value
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT"])
        #expect(fixture.notifications.removalPending)

        model.setRTCTransportRoute(.webRTC, enabled: true)
        await AppTestSupport.waitUntil { !fixture.notifications.removalPending }
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["PUT", "DELETE"])
        #expect(!fixture.notifications.removalPending)
    }

    @Test func cancelledDeviceRegistrationStopsBeforeStartingHTTP() async throws {
        let client = makeClient()
        let gate = ManualAsyncGate()
        let registering = Task {
            await gate.wait()
            try await client.registerNotificationDevice(
                origin: origin, token: token, deviceToken: Data([1]), environment: "sandbox", topic: "app")
        }
        await gate.waitForEntry()
        registering.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await registering.value }
        #expect(NotificationHTTPStub.requests.isEmpty)
    }
}
