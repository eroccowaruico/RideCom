import Foundation

extension AppCallOwner {
    @discardableResult
    func respondToGroupInvitation(_ tap: GroupInvitationTap) async -> Bool {
        guard let model = viewModel, model.accountSession === account, model.hasCurrentAccountAccess,
              let access = try? model.internetSettingsStore.notificationAccess(memberID: model.localMemberIdentity.memberID),
              access.principal.userID == tap.recipientID else { return false }
        let generation = model.accountAccessID
        await model.synchronizeGroupDeliveries()
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == generation else { return false }
        if model.hasAnyActiveGroupConnection { model.showLiveCall(); callPresentationID = UUID() }
        else { groupsPresentationID = UUID() }
        return true
    }

    /// Only the notification response callback calls this method, never arrival.
    @discardableResult
    func respondToCallNotification(_ tap: CallNotificationTap) async -> Bool {
        guard let model = viewModel, model.hasCurrentAccountAccess, model.accountSession === account else { return false }
        let accessID = model.accountAccessID
        guard let userID = await model.notifications.resolveTap(tap) else {
            // An old notice whose sender cannot be resolved opens your users, without an error.
            if viewModel === model, model.hasCurrentAccountAccess { usersPresentationID = UUID() }
            return false
        }
        guard viewModel === model, model.hasCurrentAccountAccess, model.accountAccessID == accessID else { return false }
        // In one place at a time: while connected elsewhere, the notice only opens the current call.
        if model.hasAnyActiveGroupConnection, !model.isActiveCall(.user(userID)) {
            model.showLiveCall()
            callPresentationID = UUID()
            return false
        }
        let started = model.startCall(to: .user(userID), accountAccessID: accessID, allowSwitchingCall: false)
        callPresentationID = UUID()
        return started
    }
}
