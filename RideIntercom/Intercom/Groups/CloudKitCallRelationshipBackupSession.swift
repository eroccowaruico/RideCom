import CloudKit
import Foundation

/// Binds backup to the account that can currently access the app's private database.
@MainActor
final class CloudKitCallRelationshipBackupSession {
    typealias Account = CallRelationshipBackupCheckpointStore.CloudAccount

    enum Failure: Error, Equatable { case accountUnavailable, backupChanged }

    private struct CurrentBackup {
        let backup: CallRelationshipBackup?
        let signer: DeviceIdentitySigner
        let trust: DeviceIdentityTrust
    }

    private let store: CloudKitCallRelationshipBackupStore
    private let keychain: KeychainSecretStoring
    private let namespace: String
    private let account: () async throws -> Account?
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private weak var model: IntercomViewModel?
    private var current: Account?
    private var generation = UUID()
    private(set) var task: Task<Void, Never>?

    convenience init(
        container: CKContainer, environment: CallRelationshipBackupCheckpointStore.Environment,
        keychain: KeychainSecretStoring, namespace: String
    ) {
        self.init(store: .init(container: container), keychain: keychain, namespace: namespace, center: .default) {
            guard let containerID = container.containerIdentifier,
                  try await container.accountStatus() == .available else { return nil }
            let accountID = try await container.userRecordID().recordName
            return Account(container: containerID, environment: environment, account: accountID)
        }
    }

    init(
        store: CloudKitCallRelationshipBackupStore, keychain: KeychainSecretStoring, namespace: String,
        center: NotificationCenter, account: @escaping () async throws -> Account?
    ) {
        self.store = store
        self.keychain = keychain
        self.namespace = namespace
        self.center = center
        self.account = account
        observer = center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    func bind(to model: IntercomViewModel?) {
        guard self.model !== model else { return }
        self.model?.stopCallRelationshipBackup()
        self.model = model
        refresh()
    }

    func refreshIfUnavailable() {
        if current == nil && task == nil { refresh() }
    }

    func restore(_ batch: ConfirmedCallRestore, from original: CallRelationshipBackup) async throws {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let owner = signer.principal else { throw Failure.accountUnavailable }
        _ = try original.validated(for: owner)
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let latest = checked.backup, try batch.hasUnchangedCandidates(from: original, in: latest) else {
            throw Failure.backupChanged
        }
        try model.groupRepository.restoreCallRelationships(batch, as: checked.signer, trust: checked.trust)
        model.reloadSavedGroups()
    }

    func confirmDirectRestore(_ request: CallRelationshipRestoreRequest) async throws
        -> CallRelationshipRestoreConfirmation? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner() else {
            throw Failure.accountUnavailable
        }
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let latest = checked.backup else { return nil }
        return try model.groupRepository.confirmRestore(
            request, as: checked.signer, trust: checked.trust, now: Date(), matchingDirectBackup: latest)
    }

    private func readCurrentBackup(for model: IntercomViewModel, as signer: DeviceIdentitySigner) async throws
        -> CurrentBackup {
        guard let cloud = current, let owner = signer.principal else { throw Failure.accountUnavailable }
        let expected = generation
        try await verify(cloud, generation: expected)
        let stored = try await store.load(as: signer, now: Date().timeIntervalSince1970)
        try await verify(cloud, generation: expected)
        guard let active = try model.callRelationshipBackupSigner(),
              active.principal == owner, active.memberID == signer.memberID, active.publicKey == signer.publicKey,
              let trust = try model.internetSettingsStore.identityTrust() else { throw Failure.accountUnavailable }
        return .init(backup: stored?.backup, signer: active, trust: trust)
    }

    private func invalidate() {
        generation = UUID()
        current = nil
        task?.cancel()
        task = nil
        model?.stopCallRelationshipBackup()
    }

    private func refresh() {
        invalidate()
        guard model?.hasCurrentAccountAccess == true else { return }
        let expected = generation
        task = Task { [weak self] in
            guard let self else { return }
            let found = try? await account()
            guard !Task.isCancelled, generation == expected else { return }
            task = nil
            guard let found, let model, model.hasCurrentAccountAccess, let user = model.accountUserID else { return }
            install(found, on: model, user: user, generation: expected)
        }
    }

    private func install(_ found: Account, on model: IntercomViewModel, user: String, generation expected: UUID) {
        current = found
        let scopedNamespace = AppleAccountSession.storageNamespace(base: namespace, userID: user)
        let checkpoints = CallRelationshipBackupCheckpointStore(
            keychain: keychain, namespace: scopedNamespace, cloud: found)
        let guarded = store.checkingAccess { [weak self] in
            guard let self else { throw Failure.accountUnavailable }
            try await self.verify(found, generation: expected)
        }
        model.configureCallRelationshipBackup(store: guarded, checkpoints: checkpoints) { [weak self] in
            guard let self, self.generation == expected else { return nil }
            return self.current
        }
    }

    private func verify(_ expected: Account, generation expectedGeneration: UUID) async throws {
        guard !Task.isCancelled, generation == expectedGeneration, model?.hasCurrentAccountAccess == true else {
            throw Failure.accountUnavailable
        }
        let found = try? await account()
        guard !Task.isCancelled, generation == expectedGeneration, model?.hasCurrentAccountAccess == true else {
            throw Failure.accountUnavailable
        }
        guard found == expected else {
            invalidate()
            throw Failure.accountUnavailable
        }
    }
}

private extension ConfirmedCallRestore {
    func hasUnchangedCandidates(from original: CallRelationshipBackup, in latest: CallRelationshipBackup) throws
        -> Bool {
        guard owner == original.owner, owner == latest.owner else { return false }
        guard users.allSatisfy({ user in
            guard let candidate = original.contacts.first(where: { $0.id == user.id && $0.principal == user.principal })
            else { return false }
            return latest.contacts.contains(candidate)
        }) else { return false }
        return try calls.allSatisfy { call in
            let context = call.context
            let record = context.record
            if record.kind == .direct {
                guard let peer = record.accountPair?.other(than: owner),
                      let contact = users.first(where: { $0.principal == peer }) else { return false }
                return try latest.matchesDirectRestoreRequest(context, contactID: contact.id)
            }
            guard let candidate = original.groups.first(where: { $0.id == record.id }) else { return false }
            return latest.groups.contains(candidate)
        }
    }
}
