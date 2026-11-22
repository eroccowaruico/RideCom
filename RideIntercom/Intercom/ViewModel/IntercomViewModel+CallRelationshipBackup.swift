import Foundation

extension IntercomViewModel {
    func configureCallRelationshipBackup(
        store: CloudKitCallRelationshipBackupStore, isCloudAccountCurrent: @escaping () -> Bool
    ) {
        stopCallRelationshipBackup()
        let sync = CallRelationshipBackupSync(repository: groupRepository, store: store) { [weak self] in
            guard let self, self.canStartCalls, isCloudAccountCurrent() else { return nil }
            let memberID = self.localMemberIdentity.memberID
            guard let identity = try self.internetSettingsStore.loadIdentity(memberID: memberID) else { return nil }
            return try self.internetSettingsStore.invitationSigner(
                memberID: memberID, expectedPublicKey: identity.deviceKey)
        }
        callRelationshipBackupSync = sync
        groupRepository.onCommittedChange = { [weak sync] in sync?.request() }
        sync.request()
    }

    func stopCallRelationshipBackup() {
        callRelationshipBackupSync?.stop()
        callRelationshipBackupSync = nil
        groupRepository.onCommittedChange = nil
    }
}
