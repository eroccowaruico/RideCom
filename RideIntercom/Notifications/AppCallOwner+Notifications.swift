import Foundation
import RTC

extension AppCallOwner {
    func groupInvitationRecipient(for tap: GroupInvitationTap) -> IntercomViewModel? {
        guard let model = viewModel, model.accountSession === account, model.hasCurrentAccountAccess,
              let access = try? model.internetSettingsStore.notificationAccess(
                memberID: model.localMemberIdentity.memberID),
              access.principal.userID == tap.recipientID else { return nil }
        return model
    }

    @discardableResult
    func respondToGroupInvitation(_ tap: GroupInvitationTap) async -> Bool {
        guard let model = groupInvitationRecipient(for: tap) else { return false }
        let generation = model.accountAccessID
        // An in-flight read may have taken its snapshot before this invitation arrived.
        await model.synchronizeGroupDeliveries(.notification)
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == generation else {
            return false
        }
        if model.hasAnyActiveGroupConnection {
            model.showLiveCall(); callPresentationID = UUID()
        } else {
            groupsPresentationID = UUID()
        }
        return true
    }

    /// Only the notification response callback calls this method, never arrival.
    @discardableResult
    func respondToCallNotification(_ tap: CallNotificationTap) async -> Bool {
        guard let model = viewModel, model.hasCurrentAccountAccess, model.accountSession === account,
              model.notifications.canReceive(tap) else { return false }
        let accessID = model.accountAccessID

        func showCurrentCallIfActive() -> Bool {
            guard model.hasAnyActiveGroupConnection else { return false }
            model.showLiveCall()
            callPresentationID = UUID()
            return true
        }

        if showCurrentCallIfActive() { return false }
        let notifications = model.notifications
        let resolved = model.isRTCTransportRouteEnabled(.webRTC) ? await notifications.resolveTap(tap) : nil
        guard !Task.isCancelled, viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == accessID,
              model.notifications === notifications, notifications.canReceive(tap) else { return false }
        if showCurrentCallIfActive() { return false }
        guard model.isRTCTransportRouteEnabled(.webRTC), let resolved, notifications.now() < resolved.expiresAt else {
            usersPresentationID = UUID()
            return false
        }
        let reference = model.currentCallReference
        let start = model.requestCallStart(to: .user(resolved.userID), accountAccessID: accessID,
                                           allowSwitchingCall: false) { [weak self, weak model] in
            guard let model, self?.viewModel === model, model.notifications === notifications,
                  model.isRTCTransportRouteEnabled(.webRTC) else { return false }
            return notifications.now() < resolved.expiresAt && notifications.canRespond(to: resolved, tap: tap)
        }
        let started = await presentStartedCall(start, in: model)
        if case .failed = start, !Task.isCancelled, viewModel === model, model.matchesCurrentCall(reference) {
            callPresentationID = UUID()
        }
        if case .waitingForMicrophone = start, !started, !Task.isCancelled, viewModel === model,
           model.matchesCurrentCall(reference), model.notifications === notifications,
           notifications.now() >= resolved.expiresAt, notifications.canRespond(to: resolved, tap: tap) {
            usersPresentationID = UUID()
        }
        return started
    }
}
