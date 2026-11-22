import Foundation

@MainActor final class DirectRestoreDeviceSync {
    let client: InternetAccountClient
    var task: Task<Void, Never>?
    var needsRun = false
    private var sessionBinding: String?
    var acknowledgedExpiries: [String: Int64] = [:]

    init(client: InternetAccountClient) { self.client = client }

    func useSession(_ binding: String, now: Date) {
        if sessionBinding != binding { acknowledgedExpiries.removeAll() }
        sessionBinding = binding
        acknowledgedExpiries = acknowledgedExpiries.filter { Double($0.value) > now.timeIntervalSince1970 * 1_000 }
    }
}

extension IntercomViewModel {
    var directRestoreDeviceSync: DirectRestoreDeviceSync? { callRelationshipSync.directRestoreDevice }

    private struct DirectRestoreDeviceTransport {
        let signer: DeviceIdentitySigner
        let identity: VerifiedDeviceIdentity
        let access: CallNotificationServiceAccess
    }

    func startDirectRestoreDeviceSync(using client: InternetAccountClient) {
        stopDirectRestoreDeviceSync()
        callRelationshipSync.directRestoreDevice = .init(client: client)
        groupRepository.onCommittedCallRelationshipsChange = { [weak self] in self?.requestDirectRestoreDeviceSync() }
        requestDirectRestoreDeviceSync()
    }

    func stopDirectRestoreDeviceSync() {
        groupRepository.onCommittedCallRelationshipsChange = nil
        directRestoreDeviceSync?.task?.cancel()
        callRelationshipSync.directRestoreDevice = nil
    }

    func requestDirectRestoreDeviceSync() {
        guard let sync = directRestoreDeviceSync, canEditSavedGroups else { return }
        sync.needsRun = true
        guard sync.task == nil else { return }
        sync.task = Task { [weak self, weak sync] in
            guard let sync else { return }
            repeat {
                sync.needsRun = false
                try? await self?.runDirectRestoreDeviceSync(sync)
            } while sync.needsRun && !Task.isCancelled
            sync.task = nil
        }
    }

    private func runDirectRestoreDeviceSync(_ sync: DirectRestoreDeviceSync) async throws {
        try await synchronizeDirectRestoreDeviceWithdrawals(using: sync.client)
        guard !sync.needsRun, let transport = try directRestoreDeviceTransport(),
              let binding = transport.identity.sessionBinding else { return }
        let now = Date()
        sync.useSession(binding, now: now)
        let entries = try groupRepository.directRestoreDeviceAddresses(as: transport.signer, now: now)
        for entry in entries {
            guard !sync.needsRun, try stillUsesDirectRestoreDevice(transport) else { return }
            try await publishDirectRestoreDeviceIfNeeded(entry, through: transport, in: sync)
        }
    }

    private func publishDirectRestoreDeviceIfNeeded(
        _ entry: (contactID: UUID, address: DirectRestoreDeviceAddress),
        through transport: DirectRestoreDeviceTransport, in sync: DirectRestoreDeviceSync
    ) async throws {
        guard let snapshot = groupRepository.writableSnapshot else { return }
        let now = Date()
        let freshUntil = (now.timeIntervalSince1970 + 3_600) * 1_000
        if let expiry = sync.acknowledgedExpiries[entry.address.slot], Double(expiry) > freshUntil { return }
        let active = snapshot.directRestoreDevices.filter { Double($0.expiresAt) > now.timeIntervalSince1970 * 1_000 }
        if let tracked = active.first(where: { $0.slot == entry.address.slot }) {
            guard !tracked.withdrawalPending else { return }
        } else if active.count >= TrackedDirectRestoreDevice.maximumCount { return }
        let publication = try DirectRestoreDevicePublication(at: entry.address, as: transport.signer, now: now)
        if let expiry = sync.acknowledgedExpiries[publication.slot], expiry >= publication.expiresAt { return }
        try await sendTrackedDirectRestoreDevice(publication, for: entry.contactID, through: transport,
                                                 using: sync.client, now: now)
        guard try stillUsesDirectRestoreDevice(transport) else { return }
        sync.acknowledgedExpiries[publication.slot] = publication.expiresAt
    }

    func publishTrackedDirectRestoreDevice(for contactID: UUID, using client: InternetAccountClient) async throws
        -> Bool {
        guard let transport = try directRestoreDeviceTransport() else { return false }
        let now = Date()
        guard let publication = try groupRepository.directRestoreDevicePublication(
            for: contactID, as: transport.signer, now: now) else { return false }
        try await sendTrackedDirectRestoreDevice(publication, for: contactID, through: transport,
                                                 using: client, now: now)
        return true
    }

    private func sendTrackedDirectRestoreDevice(
        _ publication: DirectRestoreDevicePublication, for contactID: UUID,
        through transport: DirectRestoreDeviceTransport, using client: InternetAccountClient, now: Date
    ) async throws {
        try groupRepository.trackDirectRestoreDevice(publication, for: contactID, as: transport.identity, now: now)
        try await client.publishDirectRestoreDevice(publication, access: transport.access)
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
