import Foundation

extension CloudKitCallRelationshipBackupSession {
    enum SelectedDirectRestorePreparation {
        case noSelection
        case selectionChanged
        case waitingForDevice
        case ready(PendingDirectRestore)
    }

    func selectDirectRestore(_ contactID: UUID, from original: CallRelationshipBackup) async throws {
        let account = try relayAccount()
        guard let checkpoints = restoreSelectionCheckpoints, let owner = account.signer.principal
        else { throw Failure.accountUnavailable }
        _ = try original.validated(for: owner)
        guard let contact = original.contacts.first(where: { $0.id == contactID }),
              contact.restoreRecipientFingerprint != nil, contact.confirmedRegistrationID != nil,
              contact.restoreDiscoverySeed != nil else { throw Failure.backupChanged }
        let change = UUID()
        restoreSelectionChange = change
        let current = try await readCurrentBackup(scopedTo: account)
        guard restoreSelectionChange == change, current.backup?.contacts.contains(contact) == true
        else { throw Failure.backupChanged }
        let selection = CallRelationshipBackupCheckpointStore.RestoreSelection(
            contactID: contactID, fingerprint: try CallRelationshipBackupCheckpointStore.fingerprint(contact))
        try checkpoints.saveRestoreSelection(selection, as: current.signer)
        retrySelectedDirectRestore()
    }

    func retrySelectedDirectRestore() {
        guard let directRestoreClient, let checkpoints = restoreSelectionCheckpoints else { return }
        directRestorePreparation?.cancel()
        directRestorePreparation = Task { [weak self] in
            guard let self else { return .noSelection }
            return try await prepareSelectedDirectRestore(in: checkpoints, using: directRestoreClient)
        }
    }

    private func prepareSelectedDirectRestore(
        in checkpoints: CallRelationshipBackupCheckpointStore, using client: InternetAccountClient
    ) async throws -> SelectedDirectRestorePreparation {
        let account = try relayAccount()
        guard let selection = try checkpoints.loadRestoreSelection(as: account.signer) else { return .noSelection }
        do {
            let checked = try await readCurrentBackup(scopedTo: account)
            try requireRestoreSelection(selection, as: checked.signer)
            guard let contact = checked.backup?.contacts.first(where: { $0.id == selection.contactID }),
                  try selection.matches(contact) else { throw Failure.backupChanged }
            let pending = try await prepareSelectedDirectRestore(selection, checked: checked,
                                                                 scopedTo: account, using: client)
            try requireRelayAccount(account)
            try requireRestoreSelection(selection, as: checked.signer)
            return pending.map(SelectedDirectRestorePreparation.ready) ?? .waitingForDevice
        } catch Failure.backupChanged {
            try requireRelayAccount(account)
            if try checkpoints.loadRestoreSelection(as: account.signer) == selection {
                try checkpoints.saveRestoreSelection(nil, as: account.signer)
            }
            return .selectionChanged
        }
    }

    func requireRestoreSelection(_ expected: CallRelationshipBackupCheckpointStore.RestoreSelection?,
                                 as signer: DeviceIdentitySigner) throws {
        guard let expected else { return }
        guard let checkpoints = restoreSelectionCheckpoints,
              try checkpoints.loadRestoreSelection(as: signer) == expected
        else { throw Failure.backupChanged }
    }
}
