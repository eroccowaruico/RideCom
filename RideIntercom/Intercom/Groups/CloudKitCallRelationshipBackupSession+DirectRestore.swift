import Foundation

extension CloudKitCallRelationshipBackupSession {
    func prepareDirectRestore(
        for contactID: UUID, candidates: [DeviceIdentityCertificate], from original: CallRelationshipBackup
    ) async throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        let (model, signer) = try activeBackupSigner()
        let (latest, checked) = try await checkDirectRestoreContact(contactID, from: original, for: model, as: signer)
        return try directRestoreRequest(for: contactID, in: latest, candidates: candidates, after: checked, now: Date())
    }

    func prepareDirectRestore(
        for contactID: UUID, from original: CallRelationshipBackup, using client: InternetAccountClient
    ) async throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        let account = try relayAccount()
        guard let model else { throw Failure.accountUnavailable }
        let (_, checked) = try await checkDirectRestoreContact(
            contactID, from: original, for: model, as: account.signer)
        return try await prepareDirectRestore(for: contactID, checked: checked, account: account, using: client)
    }

    func prepareDirectRestore(
        for contactID: UUID, checked: CurrentBackup, account: RelayAccount, using client: InternetAccountClient
    ) async throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        try requireRelayAccount(account)
        guard let model, let latest = checked.backup else { throw Failure.backupChanged }
        guard let address = try latest.directRestoreDeviceAddress(for: contactID, as: checked.signer, now: Date())
        else { return nil }
        let received = try await client.fetchDirectRestoreDevice(at: address, access: account.access)
        try requireRelayAccount(account)
        let (current, resolved) = try await checkDirectRestoreContact(
            contactID, from: latest, for: model, as: account.signer)
        try requireRelayAccount(account)
        guard let received else { return nil }
        let now = Date()
        if received.expiresAt > 0, Double(received.expiresAt) <= now.timeIntervalSince1970 * 1_000 { return nil }
        let certificate = try received.open(at: address, as: resolved.signer, trust: resolved.trust, now: now)
        return try directRestoreRequest(
            for: contactID, in: current, candidates: [certificate], after: resolved, now: now)
    }

    private func directRestoreRequest(
        for contactID: UUID, in backup: CallRelationshipBackup, candidates: [DeviceIdentityCertificate],
        after checked: CurrentBackup, now: Date
    ) throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        guard let recipient = try backup.directRestoreRecipient(
            for: contactID, from: candidates, trust: checked.trust, now: now),
              let request = try backup.directRestoreRequest(for: contactID, to: recipient, as: checked.signer, now: now)
        else { return nil }
        return (recipient, request)
    }

    func checkDirectRestoreContact(
        _ contactID: UUID, from original: CallRelationshipBackup,
        for model: IntercomViewModel, as signer: DeviceIdentitySigner
    ) async throws -> (CallRelationshipBackup, CurrentBackup) {
        guard let owner = signer.principal else { throw Failure.accountUnavailable }
        _ = try original.validated(for: owner)
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let latest = checked.backup, original.unchangedContact(contactID, in: latest) != nil else {
            throw Failure.backupChanged
        }
        return (latest, checked)
    }
}
