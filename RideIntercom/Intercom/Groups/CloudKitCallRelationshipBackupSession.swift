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

    func prepareDirectRestore(
        for contactID: UUID, candidates: [DeviceIdentityCertificate], from original: CallRelationshipBackup
    ) async throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner()
        else { throw Failure.accountUnavailable }
        let (latest, checked) = try await checkDirectRestoreContact(contactID, from: original, for: model, as: signer)
        return try directRestoreRequest(for: contactID, in: latest, candidates: candidates, after: checked, now: Date())
    }

    func prepareDirectRestore(
        for contactID: UUID, from original: CallRelationshipBackup, using client: InternetAccountClient
    ) async throws -> (recipient: VerifiedDeviceIdentity, request: CallRelationshipRestoreRequest)? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let access = try model.internetSettingsStore.notificationAccess(memberID: signer.memberID)
        else { throw Failure.accountUnavailable }
        let expected = generation
        let (latest, checked) = try await checkDirectRestoreContact(contactID, from: original, for: model, as: signer)
        guard try model.internetSettingsStore.notificationAccess(memberID: signer.memberID) == access,
              generation == expected else { throw Failure.accountUnavailable }
        guard let address = try latest.directRestoreDeviceAddress(for: contactID, as: checked.signer, now: Date())
        else { return nil }
        let received = try await client.fetchDirectRestoreDevice(at: address, access: access)
        guard generation == expected else { throw Failure.accountUnavailable }
        let (current, resolved) = try await checkDirectRestoreContact(
            contactID, from: original, for: model, as: signer)
        guard try model.internetSettingsStore.notificationAccess(memberID: signer.memberID) == access,
              generation == expected else { throw Failure.accountUnavailable }
        guard let received else { return nil }
        let now = Date()
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

    private func checkDirectRestoreContact(
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

    func restoreDirect(
        _ response: DirectCallRestoreResponse, to request: CallRelationshipRestoreRequest,
        for contactID: UUID, from original: CallRelationshipBackup
    ) async throws {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let owner = signer.principal, let trust = try model.internetSettingsStore.identityTrust() else {
            throw Failure.accountUnavailable
        }
        _ = try original.validated(for: owner)
        guard let contact = original.contacts.first(where: { $0.id == contactID }) else { throw Failure.backupChanged }
        let batch = try response.restoreBatch(for: request, contact: contact,
            localDisplayName: model.localMemberIdentity.displayName, as: signer, verifying: (trust, Date()))
        try await restore(batch, from: original)
    }

    func respondToDirectRestore(_ request: CallRelationshipRestoreRequest) async throws -> DirectCallRestoreResponse? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let trust = try model.internetSettingsStore.identityTrust() else {
            throw Failure.accountUnavailable
        }
        let expected = generation
        guard let requester = try request.verifiedDirectRequester(addressedTo: signer, trust: trust, now: Date()),
              await model.refreshContactDeletionBeforeRestore(requester, addressedTo: signer) else { return nil }
        guard generation == expected else { throw Failure.accountUnavailable }
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let latest = checked.backup else { return nil }
        return try model.groupRepository.sealDirectRestore(
            request, as: checked.signer, trust: checked.trust, now: Date(), matching: latest)
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

private extension CallRelationshipBackup {
    func unchangedContact(_ id: UUID, in latest: Self) -> Contact? {
        guard owner == latest.owner, let contact = contacts.first(where: { $0.id == id }),
              latest.contacts.contains(contact) else { return nil }
        return contact
    }
}

private extension ConfirmedCallRestore {
    func hasUnchangedCandidates(from original: CallRelationshipBackup, in latest: CallRelationshipBackup) throws
        -> Bool {
        guard owner == original.owner, owner == latest.owner else { return false }
        guard users.allSatisfy({ user in
            guard let candidate = original.unchangedContact(user.id, in: latest) else { return false }
            return candidate.principal == user.principal
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
