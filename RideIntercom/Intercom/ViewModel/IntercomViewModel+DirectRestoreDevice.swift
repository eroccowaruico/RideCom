import Foundation

extension IntercomViewModel {
    private struct DirectRestoreDeviceTransport {
        let signer: DeviceIdentitySigner
        let identity: VerifiedDeviceIdentity
        let access: CallNotificationServiceAccess
    }

    func publishTrackedDirectRestoreDevice(for contactID: UUID, using client: InternetAccountClient) async throws
        -> Bool {
        guard let transport = try directRestoreDeviceTransport() else { return false }
        let now = Date()
        guard let publication = try groupRepository.directRestoreDevicePublication(
            for: contactID, as: transport.signer, now: now) else { return false }
        try groupRepository.trackDirectRestoreDevice(publication, for: contactID, as: transport.identity, now: now)
        try await client.publishDirectRestoreDevice(publication, access: transport.access)
        return true
    }

    func synchronizeDirectRestoreDeviceWithdrawals(using client: InternetAccountClient) async throws {
        guard let transport = try directRestoreDeviceTransport(),
              let snapshot = groupRepository.writableSnapshot else { return }
        for record in snapshot.directRestoreDevices where record.withdrawalPending
            && record.publisher == transport.access.principal && record.deviceID == transport.identity.deviceID {
            guard Double(record.expiresAt) > Date().timeIntervalSince1970 * 1_000 else { continue }
            guard try stillUsesDirectRestoreDevice(transport) else { return }
            try await client.revokeDirectRestoreDevice(record.withdrawal, access: transport.access)
            guard try stillUsesDirectRestoreDevice(transport) else { return }
            try groupRepository.finishDirectRestoreWithdrawal(record, now: Date())
        }
    }

    private func stillUsesDirectRestoreDevice(_ transport: DirectRestoreDeviceTransport) throws -> Bool {
        guard let current = try directRestoreDeviceTransport() else { return false }
        return current.identity.deviceID == transport.identity.deviceID && current.access == transport.access
    }

    private func directRestoreDeviceTransport() throws -> DirectRestoreDeviceTransport? {
        guard canEditSavedGroups, !Task.isCancelled, let signer = try callRelationshipBackupSigner(),
              let identity = signer.identity,
              let access = try internetSettingsStore.notificationAccess(memberID: identity.memberID),
              access.principal == AccountPrincipal(issuer: identity.issuer, userID: identity.userID)
        else { return nil }
        return .init(signer: signer, identity: identity, access: access)
    }
}
