import Foundation

extension IntercomViewModel {
    var groupTabInvitationOffer: IntercomGroup? {
        _ = contactInvitationRevision
        guard interfaceMode == .standard, !showsGroupsTab, canEditSavedGroups, !hasAnyActiveGroupConnection else { return nil }
        return groupRepository.unacknowledgedGroupTabOffers.first.flatMap { groupRepository.storedGroup($0) }
    }

    @discardableResult
    func acknowledgeGroupTabInvitationOffer(_ id: UUID) -> Bool {
        guard groupTabInvitationOffer?.id == id else { return false }
        do {
            try groupRepository.acknowledgeGroupTabOffers()
            refreshGroupStorageStatus()
            return true
        } catch { reportGroupStorageError(error); return false }
    }
    @discardableResult
    func acknowledgeVisibleGroupTabInvitations() -> Bool {
        guard isGroupsTabVisible, canEditSavedGroups else { return false }
        guard !groupRepository.unacknowledgedGroupTabOffers.isEmpty else { return true }
        do {
            try groupRepository.acknowledgeGroupTabOffers()
            refreshGroupStorageStatus()
            return true
        } catch { reportGroupStorageError(error); return false }
    }

}
