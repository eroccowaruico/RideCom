import CloudKit
import Foundation

/// Binds backup to the account that can currently access the app's private database.
@MainActor
final class CloudKitCallRelationshipBackupSession {
    typealias Account = CallRelationshipBackupCheckpointStore.CloudAccount

    enum Failure: Error, Equatable { case accountUnavailable }

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
