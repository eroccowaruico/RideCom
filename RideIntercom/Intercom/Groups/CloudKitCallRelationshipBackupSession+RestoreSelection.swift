import Foundation

extension CloudKitCallRelationshipBackupSession {
    enum SelectedDirectRestorePreparation {
        case noSelection
        case selectionChanged
        case waitingForDevice
        case ready(PendingDirectRestore)
        case restored
    }

    func selectDirectRestore(_ contactID: UUID, from original: CallRelationshipBackup) async throws {
        let account = try relayAccount()
        guard let checkpoints = restoreSelectionCheckpoints, let owner = account.signer.principal
        else { throw Failure.accountUnavailable }
        _ = try original.validated(for: owner)
        guard let contact = original.contacts.first(where: { $0.id == contactID }),
              contact.restoreRecipientFingerprint != nil, contact.confirmedRegistrationID != nil,
              contact.restoreDiscoverySeed != nil else { throw Failure.backupChanged }
        guard model?.groupRepository.canRestoreDirectContact(contactID, peer: contact.principal, owner: owner) == true
        else { throw GroupStorageError.invalidUpdate }
        let change = UUID()
        restoreSelectionChange = change
        let current = try await readCurrentBackup(scopedTo: account)
        guard restoreSelectionChange == change, current.backup?.contacts.contains(contact) == true
        else { throw Failure.backupChanged }
        guard model?.groupRepository.canRestoreDirectContact(contactID, peer: contact.principal, owner: owner) == true
        else { throw GroupStorageError.invalidUpdate }
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
        if await resumeCompletedDirectRestore(in: account, using: client) { return .restored }
        try requireRelayAccount(account)
        guard let progress = try checkpoints.loadRestoreProgress(as: account.signer) else { return .noSelection }
        let selection = progress.selection
        do {
            let checked = try await readCurrentBackup(scopedTo: account)
            try requireRestoreSelection(selection, as: checked.signer)
            guard let backup = checked.backup,
                  let contact = backup.contacts.first(where: { $0.id == selection.contactID }),
                  try selection.matches(contact),
                  model?.groupRepository.canRestoreDirectContact(contact.id, peer: contact.principal,
                                                                 owner: backup.owner) == true
            else { throw Failure.backupChanged }
            return try await sendSelectedDraft(progress, checked: checked, scopedTo: account,
                                               in: checkpoints, using: client)
        } catch Failure.backupChanged {
            try requireRelayAccount(account)
            if try checkpoints.loadRestoreSelection(as: account.signer) == selection {
                try checkpoints.saveRestoreSelection(nil, as: account.signer)
            }
            return .selectionChanged
        }
    }

    private func sendSelectedDraft(
        _ saved: CallRelationshipBackupCheckpointStore.RestoreProgress, checked: CurrentBackup,
        scopedTo account: RelayAccount, in checkpoints: CallRelationshipBackupCheckpointStore,
        using client: InternetAccountClient
    ) async throws -> SelectedDirectRestorePreparation {
        guard let backup = checked.backup else { throw Failure.backupChanged }
        let selection = saved.selection
        var progress = saved
        if let draft = progress.draft, try !draft.isCurrent(for: selection.contactID, in: backup,
                                                            as: account.signer, trust: account.trust, now: Date()) {
            progress.draft = nil
            try checkpoints.saveRestoreProgress(progress, as: account.signer)
        }
        let pending: PendingDirectRestore
        if let draft = progress.draft {
            let submission = DirectCallRestoreRelaySubmission(sender: account.access.principal, payload: draft.payload)
            pending = .init(account: account, contactID: selection.contactID, backup: backup,
                            request: draft.request, submission: submission, selection: selection)
        } else {
            guard let prepared = try await prepareSelectedDirectRestore(selection, checked: checked,
                                                                        scopedTo: account, using: client)
            else { return .waitingForDevice }
            pending = prepared
            progress.draft = pending.requestDraft
            try checkpoints.saveRestoreProgress(progress, as: account.signer)
        }
        if progress.draft?.needsSubmission(at: Date()) == true {
            try await sendRelayedDirectRestore(pending, using: client)
            try requireRelayAccount(account)
            guard try checkpoints.loadRestoreProgress(as: account.signer) == progress
            else { throw CancellationError() }
            progress.draft?.submitted = true
            try checkpoints.saveRestoreProgress(progress, as: account.signer)
        }
        if try await finishRelayedDirectRestore(pending, using: client) { return .restored }
        return .ready(pending)
    }

    private func prepareSelectedDirectRestore(
        _ selection: CallRelationshipBackupCheckpointStore.RestoreSelection, checked: CurrentBackup,
        scopedTo account: RelayAccount, using client: InternetAccountClient
    ) async throws -> PendingDirectRestore? {
        let id = selection.contactID
        guard let backup = checked.backup, let prepared = try await prepareDirectRestore(
            for: id, checked: checked, account: account, using: client) else { return nil }
        try requireRestoreSelection(selection, as: account.signer)
        let submission = try DirectCallRestoreRelayPacket.seal(
            .request(value: prepared.request), to: prepared.recipient, as: account.signer, now: Date())
        return .init(account: account, contactID: id, backup: backup, request: prepared.request,
                     submission: submission, selection: selection)
    }

    func requireRestoreSelection(_ expected: CallRelationshipBackupCheckpointStore.RestoreSelection?,
                                 as signer: DeviceIdentitySigner) throws {
        guard let expected else { return }
        guard let checkpoints = restoreSelectionCheckpoints,
              try checkpoints.loadRestoreSelection(as: signer) == expected
        else { throw Failure.backupChanged }
    }
}
