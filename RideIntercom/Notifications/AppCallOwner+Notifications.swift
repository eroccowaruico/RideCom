import Foundation

extension AppCallOwner {
    @discardableResult
    func respondToGroupInvitation(_ tap: GroupInvitationTap) async -> Bool {
        guard let model = viewModel, model.accountSession === account, model.hasCurrentAccountAccess,
              let access = try? model.internetSettingsStore.notificationAccess(memberID: model.localMemberIdentity.memberID),
              access.principal.userID == tap.recipientID else { return false }
        let generation = model.accountAccessID
        // An in-flight read may have taken its snapshot before this invitation arrived.
        await model.synchronizeGroupDeliveries(.notification)
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == generation else { return false }
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
        let userID = await model.notifications.resolveTap(tap)
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == accessID,
              model.notifications.canReceive(tap) else { return false }
        if showCurrentCallIfActive() { return false }
        guard let userID else {
            usersPresentationID = UUID()
            return false
        }
        let started = model.startCall(to: .user(userID), accountAccessID: accessID, allowSwitchingCall: false)
        callPresentationID = UUID()
        return started
    }
}
