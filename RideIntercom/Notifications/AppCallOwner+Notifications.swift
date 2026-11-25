import Foundation

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
        let resolved = await notifications.resolveTap(tap)
        guard !Task.isCancelled, viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == accessID,
              model.notifications === notifications, notifications.canReceive(tap) else { return false }
        if showCurrentCallIfActive() { return false }
        guard let resolved, notifications.now() < resolved.expiresAt else {
            usersPresentationID = UUID()
            return false
        }
        let reference = model.currentCallReference
        let authorized = await model.requestMicrophoneAccess()
        guard !Task.isCancelled, viewModel === model, model.hasCurrentAccountAccess,
              model.currentCallReference == reference, model.notifications === notifications,
              notifications.canRespond(to: resolved, tap: tap) else { return false }
        guard notifications.now() < resolved.expiresAt else {
            usersPresentationID = UUID()
            return false
        }
        guard authorized else {
            model.showsCallMicrophonePermissionAlert = true
            return false
        }
        let started = model.startCall(to: .user(resolved.userID), accountAccessID: accessID, allowSwitchingCall: false)
        callPresentationID = UUID()
        return started
    }
}
