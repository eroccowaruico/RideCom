#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1))) func lateNotificationAddressChangesCannotUndoCurrentDeviceSettings() async throws {
        try await withWorker {
            let receiver = GroupDeliveryTestIdentity("ordered-device-receiver")
            let sender = GroupDeliveryTestIdentity("ordered-device-sender")
            defer { receiver.remove(); sender.remove() }
            try await register(receiver)
            try await register(sender)
            let client = InternetAccountClient(session: workerSession())
            let access = try #require(try receiver.store.notificationAccess(memberID: receiver.memberID))
            let author = try #require(try sender.store.notificationAccess(memberID: sender.memberID))
            let grant = try await client.issueNotificationGrant(
                origin: access.origin, token: access.accessToken, senderUserID: author.principal.userID)
            let token = Data(repeating: 19, count: 48)
            let notifications = notificationDeviceModel(receiver, client: client)

            await enableDevice(notifications, token: token)
            #expect(try await deliverNotification(grant, from: author, client: client) == .accepted)
            await notifications.disable()
            #expect(!notifications.removalPending)
            await #expect(throws: InternetAccountClient.Failure.self) {
                try await client.registerNotificationDevice(
                    access: access, deviceToken: token, environment: "sandbox", topic: "fixture-app", revision: 1)
            }
            #expect(try await deliverNotification(grant, from: author, client: client) == .noDestinations)

            let reopened = notificationDeviceModel(receiver, client: client)
            await enableDevice(reopened, token: token)
            await #expect(throws: InternetAccountClient.Failure.self) {
                try await client.removeNotificationDevice(access: access, revision: 2)
            }
            #expect(try await deliverNotification(grant, from: author, client: client) == .accepted)

            try await register(receiver)
            let renewed = notificationDeviceModel(receiver, client: client)
            await enableDevice(renewed, token: token)
            await #expect(throws: InternetAccountClient.Failure.self) {
                try await client.removeNotificationDevice(access: access, revision: 5)
            }
            #expect(try await deliverNotification(grant, from: author, client: client) == .accepted)
            let current = try #require(try receiver.store.notificationAccess(memberID: receiver.memberID))
            await #expect(throws: InternetAccountClient.Failure.self) {
                try await client.removeNotificationDevice(access: current, revision: 4)
            }
            try await client.removeNotificationDevice(access: current, revision: 5)
            #expect(try await deliverNotification(grant, from: author, client: client) == .noDestinations)
        }
    }

    private func notificationDeviceModel(
        _ identity: GroupDeliveryTestIdentity, client: InternetAccountClient
    ) -> CallNotifications {
        let store = InternetConnectionSettingsStore(keychain: identity.keychain, namespace: identity.namespace)
        return CallNotifications(store: store, memberID: identity.memberID, client: client,
            isCurrentUser: { true }, contacts: { [] }, requestAuthorization: { true }, register: {}, unregister: {})
    }

    private func enableDevice(_ notifications: CallNotifications, token: Data) async {
        await notifications.enable()
        await notifications.receivedDeviceToken(token, environment: "sandbox", topic: "fixture-app")
        #expect(notifications.receivesNotifications)
    }

    private func deliverNotification(
        _ grant: CallNotificationGrant, from access: CallNotificationServiceAccess, client: InternetAccountClient
    ) async throws -> CallNotificationStatus {
        try await client.sendCallNotification(origin: access.origin, token: access.accessToken,
                                              capability: grant.capability, requestID: UUID()).status
    }
}
#endif
