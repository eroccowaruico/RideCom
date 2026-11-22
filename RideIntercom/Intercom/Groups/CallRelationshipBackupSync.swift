import Foundation

/// Serializes backup requests for one signed-in app session and one iCloud account.
@MainActor
final class CallRelationshipBackupSync {
    enum Status: Equatable {
        case idle
        case pending
        case saved
        case retryPending
        case requiresReconciliation
    }

    private let repository: GroupRepository
    private let store: CloudKitCallRelationshipBackupStore
    private let checkpoints: CallRelationshipBackupCheckpointStore
    private let activeSigner: () throws -> DeviceIdentitySigner?
    private var pending = false
    private(set) var task: Task<Void, Never>?
    private(set) var status: Status = .idle

    init(
        repository: GroupRepository, store: CloudKitCallRelationshipBackupStore,
        checkpoints: CallRelationshipBackupCheckpointStore,
        activeSigner: @escaping () throws -> DeviceIdentitySigner?
    ) {
        self.repository = repository
        self.store = store
        self.checkpoints = checkpoints
        self.activeSigner = activeSigner
    }

    func request() {
        pending = true
        status = .pending
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drainRequests() }
    }

    func stop() {
        pending = false
        task?.cancel()
        status = .idle
    }

    private func drainRequests() async {
        defer { task = nil }
        while pending && !Task.isCancelled {
            pending = false
            do {
                try await saveCurrentSnapshot()
            } catch {
                if !Task.isCancelled { status = .retryPending }
            }
        }
    }

    private func saveCurrentSnapshot() async throws {
        guard let signer = try activeSigner() else { status = .idle; return }
        let now = Date().timeIntervalSince1970
        let local = try repository.callRelationshipBackup(as: signer, now: now)
        let checkpoint = try checkpoints.load(as: signer)
        let localFingerprint = try CallRelationshipBackupCheckpointStore.fingerprint(local)
        if checkpoint?.saved == localFingerprint && checkpoint?.pending == nil {
            status = .saved
            return
        }
        if local.isEmpty, checkpoint == nil || repository.writableSnapshot?.lastBackupRemoval == nil {
            status = checkpoint == nil ? .idle : .requiresReconciliation
            return
        }

        let remote = try await store.load(as: signer, now: now)
        guard !pending, let current = try signerMatching(signer) else { return }
        let commitTime = Date().timeIntervalSince1970
        let candidate = try repository.callRelationshipBackup(as: current, now: commitTime)
        let removal = candidate.isEmpty ? repository.writableSnapshot?.lastBackupRemoval : nil
        guard !candidate.isEmpty || (checkpoint != nil && removal != nil) else {
            status = checkpoint == nil ? .idle : .requiresReconciliation
            return
        }
        let candidateFingerprint = try CallRelationshipBackupCheckpointStore.fingerprint(candidate)
        let remoteFingerprint = try remote.map { try CallRelationshipBackupCheckpointStore.fingerprint($0.backup) }
        if remoteFingerprint == candidateFingerprint {
            try checkpoints.save(.init(saved: candidateFingerprint, pending: nil), as: current)
            status = .saved
            return
        }
        guard checkpoint?.matches(remoteFingerprint) ?? (remoteFingerprint == nil) else {
            status = .requiresReconciliation
            return
        }
        guard !candidate.isEmpty || (remote != nil && removal?.fingerprint == remoteFingerprint) else {
            status = .requiresReconciliation
            return
        }

        try checkpoints.save(.init(saved: remoteFingerprint, pending: candidateFingerprint), as: current)
        _ = try await store.save(candidate, replacing: remote, as: current, now: commitTime, clearing: removal)
        guard try signerMatching(current) != nil else { return }
        try checkpoints.save(.init(saved: candidateFingerprint, pending: nil), as: current)
        if !pending { status = .saved }
    }

    private func signerMatching(_ previous: DeviceIdentitySigner) throws -> DeviceIdentitySigner? {
        guard !Task.isCancelled else { return nil }
        guard let signer = try activeSigner(), signer.principal == previous.principal,
              signer.publicKey == previous.publicKey else { status = .idle; return nil }
        return signer
    }
}
