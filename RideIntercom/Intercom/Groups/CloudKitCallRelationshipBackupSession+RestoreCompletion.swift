import Foundation

extension CloudKitCallRelationshipBackupSession {
    struct SelectedRestoreCompletion {
        let selection: CallRelationshipBackupCheckpointStore.RestoreSelection
        let receipt: DirectRestoreCompletion

        init(_ selection: CallRelationshipBackupCheckpointStore.RestoreSelection,
             response: DirectCallRestoreRelayPacket.Delivery, in account: RelayAccount) throws {
            guard let identity = account.signer.identity, let binding = identity.sessionBinding
            else { throw Failure.accountUnavailable }
            self.selection = selection
            receipt = .init(owner: account.access.principal, deviceID: identity.deviceID, sessionBinding: binding,
                            selectionID: selection.id, responseID: response.id, expiresAt: response.expiresAt)
        }
    }

    func resumeCompletedDirectRestore(in account: RelayAccount, using client: InternetAccountClient) async -> Bool {
        guard let repository = model?.groupRepository, let checkpoints = restoreSelectionCheckpoints,
              let receipt = repository.writableSnapshot?.completedDirectRestore,
              let identity = account.signer.identity, receipt.belongs(to: identity) else { return false }
        do {
            try requireRelayAccount(account)
            if try checkpoints.loadRestoreSelection(as: account.signer)?.id == receipt.selectionID {
                try checkpoints.saveRestoreSelection(nil, as: account.signer)
            }
            if receipt.canRetire(in: identity, now: Date()) {
                do {
                    try await client.retireDirectRestorePacket(receipt.responseID, access: account.access)
                } catch InternetAccountClient.Failure.notFound { /* The response already left this inbox. */ }
            }
            try requireRelayAccount(account)
            try repository.removeDirectRestoreCompletion(receipt)
        } catch {
            // The saved call is usable. Leave the receipt for the next sync.
        }
        return true
    }
}
