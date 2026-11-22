import Foundation

struct CallRelationshipSyncState {
    var backup: CallRelationshipBackupSync?
    var directRestoreDevice: DirectRestoreDeviceSync?
    var resumeDirectRestore: (() -> Void)?
}

extension IntercomViewModel {
    var callRelationshipBackupSync: CallRelationshipBackupSync? { callRelationshipSync.backup }

    func callRelationshipBackupSigner() throws -> DeviceIdentitySigner? {
        guard canStartCalls else { return nil }
        let memberID = localMemberIdentity.memberID
        guard let identity = try internetSettingsStore.loadIdentity(memberID: memberID) else { return nil }
        return try internetSettingsStore.invitationSigner(memberID: memberID, expectedPublicKey: identity.deviceKey)
    }

    func configureCallRelationshipBackup(
        store: CloudKitCallRelationshipBackupStore, checkpoints: CallRelationshipBackupCheckpointStore,
        currentCloudAccount: @escaping () -> CallRelationshipBackupCheckpointStore.CloudAccount?
    ) {
        stopCallRelationshipBackup()
        let sync = CallRelationshipBackupSync(
            repository: groupRepository, store: store, checkpoints: checkpoints
        ) { [weak self] in
            guard currentCloudAccount() == checkpoints.cloud else { return nil }
            return try self?.callRelationshipBackupSigner()
        }
        callRelationshipSync.backup = sync
        groupRepository.onCommittedChange = { [weak sync] in sync?.request() }
        sync.request()
    }

    func stopCallRelationshipBackup() {
        callRelationshipBackupSync?.stop()
        callRelationshipSync.backup = nil
        groupRepository.onCommittedChange = nil
    }

    func applyRestoredDirectCall(_ id: UUID) {
        guard let call = groupRepository.storedGroup(id) else { return }
        groups.append(call)
        refreshGroupStorageStatus()
        requestGroupDeliverySync(.localChange)
    }
}
