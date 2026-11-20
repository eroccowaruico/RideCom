import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native callbacks route to the current account owner; arrival never starts a call.
@MainActor
final class AppNotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    private weak var owner: AppCallOwner?
    func bind(to owner: AppCallOwner) {
        self.owner = owner
        if NotificationSystem.permitsSystemAccess {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories([NotificationSystem.callRequestCategory, NotificationSystem.groupInvitationCategory])
        }
    }
    func receivedDeviceToken(_ token: Data) {
        guard NotificationSystem.permitsSystemAccess, let model = owner?.viewModel, model.hasCurrentAccountAccess, let topic = Bundle.main.bundleIdentifier else { return }
        Task { await model.notifications.receivedDeviceToken(token, environment: NotificationSystem.environment, topic: topic) }
    }
    func registrationFailed() { owner?.viewModel?.notifications.registrationFailed() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard SystemSurfaceScope.permitsSystemAccess else { return }
        if let group = GroupInvitationTap(payload: response.notification.request.content.userInfo) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier { _ = await owner?.respondToGroupInvitation(group) }
            return
        }
        guard let tap = CallNotificationTap(payload: response.notification.request.content.userInfo) else { return }
        _ = await respond(to: tap, actionIdentifier: response.actionIdentifier,
                          categoryIdentifier: response.notification.request.content.categoryIdentifier)
    }
    @discardableResult
    func respond(to tap: CallNotificationTap, actionIdentifier: String, categoryIdentifier: String) async -> Bool {
        // Ignore (and anything else) only closes the notification: nothing is read or sent.
        guard actionIdentifier == UNNotificationDefaultActionIdentifier
                || (actionIdentifier == NotificationSystem.connectActionIdentifier
                    && categoryIdentifier == NotificationSystem.callRequestCategoryIdentifier) else { return false }
        return await owner?.respondToCallNotification(tap) ?? false
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard SystemSurfaceScope.permitsSystemAccess else { return [] }
        if let group = GroupInvitationTap(payload: notification.request.content.userInfo) { return await groupPresentationOptions(for: group) }
        guard let tap = CallNotificationTap(payload: notification.request.content.userInfo) else { return [] }
        return await presentationOptions(for: tap)
    }
    func groupPresentationOptions(for tap: GroupInvitationTap) -> UNNotificationPresentationOptions {
        guard let owner, let model = owner.viewModel, model.accountSession === owner.account, model.hasCurrentAccountAccess,
              let access = try? model.internetSettingsStore.notificationAccess(memberID: model.localMemberIdentity.memberID),
              access.principal.userID == tap.recipientID else { return [] }
        model.requestGroupDeliverySync(.notification)
        return [.list]
    }
    func presentationOptions(for tap: CallNotificationTap) -> UNNotificationPresentationOptions {
        guard let owner, let model = owner.viewModel, model.accountSession === owner.account,
              model.hasCurrentAccountAccess, model.notifications.canReceive(tap) else { return [] }
        // A call includes waiting for peers and paused audio. Arrival never interrupts it.
        return model.hasAnyActiveGroupConnection ? [.list] : [.banner, .list, .sound]
    }
}

#if os(macOS)
extension RideIntercomApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { notificationBridge?.receivedDeviceToken(token) }
    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) { notificationBridge?.registrationFailed() }
}
#else
@MainActor
final class RideIntercomApplicationDelegate: NSObject, UIApplicationDelegate {
    var notificationBridge: AppNotificationBridge?
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { notificationBridge?.receivedDeviceToken(token) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) { notificationBridge?.registrationFailed() }
}
#endif
