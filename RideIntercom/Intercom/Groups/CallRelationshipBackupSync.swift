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
    private let activeSigner: () throws -> DeviceIdentitySigner?
    private var pending = false
    private var lastSaved: CallRelationshipBackup?
    private(set) var task: Task<Void, Never>?
    private(set) var status: Status = .idle

    init(
        repository: GroupRepository, store: CloudKitCallRelationshipBackupStore,
        activeSigner: @escaping () throws -> DeviceIdentitySigner?
    ) {
        self.repository = repository
        self.store = store
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
        lastSaved = nil
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
        let localData = try repository.callRelationshipBackup(as: signer, now: now)
        let local = try CallRelationshipBackup.read(localData, as: signer, now: now)
        guard !local.groups.isEmpty || !local.contacts.isEmpty else {
            status = lastSaved == nil ? .idle : .requiresReconciliation
            return
        }
        guard local != lastSaved else { status = .saved; return }

        let remote = try await store.load(as: signer, now: now)
        guard !pending, let current = try signerMatching(signer) else { return }
        let commitTime = Date().timeIntervalSince1970
        let latest = try repository.callRelationshipBackup(as: current, now: commitTime)
        let candidate = try CallRelationshipBackup.read(latest, as: current, now: commitTime)
        guard !candidate.groups.isEmpty || !candidate.contacts.isEmpty else {
            status = lastSaved == nil ? .idle : .requiresReconciliation
            return
        }
        if remote?.backup == candidate {
            lastSaved = candidate
            status = .saved
            return
        }
        guard remote?.backup == lastSaved else { status = .requiresReconciliation; return }

        let result = try await store.save(latest, replacing: remote, as: current, now: commitTime)
        guard try signerMatching(current) != nil else { return }
        lastSaved = result.backup
        if !pending { status = .saved }
    }

    private func signerMatching(_ previous: DeviceIdentitySigner) throws -> DeviceIdentitySigner? {
        guard !Task.isCancelled else { return nil }
        guard let signer = try activeSigner(), signer.principal == previous.principal,
              signer.publicKey == previous.publicKey else { status = .idle; return nil }
        return signer
    }
}
