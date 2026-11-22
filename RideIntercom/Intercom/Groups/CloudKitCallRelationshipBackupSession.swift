import CloudKit
import Foundation

/// Binds backup to the account that can currently access the app's private database.
@MainActor
final class CloudKitCallRelationshipBackupSession {
    typealias Account = CallRelationshipBackupCheckpointStore.CloudAccount

    enum Failure: Error, Equatable { case accountUnavailable, backupChanged, requestExpired }

    struct CurrentBackup {
        let backup: CallRelationshipBackup?
        let signer: DeviceIdentitySigner
        let trust: DeviceIdentityTrust
    }

    private let store: CloudKitCallRelationshipBackupStore
    private let keychain: KeychainSecretStoring
    private let namespace: String
    private let account: () async throws -> Account?
    private let center: NotificationCenter
    let directRestoreClient: InternetAccountClient?
    private(set) var restoreSelectionCheckpoints: CallRelationshipBackupCheckpointStore?
    var directRestorePreparation: Task<SelectedDirectRestorePreparation, Error>?
    var directRestoreInboxTask: Task<Int, Error>?
    var restoreInboxRun: UUID?
    var restoreInboxNeedsRetry = false
    var restoreSelectionChange = UUID()
    private var observer: NSObjectProtocol?
    private(set) weak var model: IntercomViewModel?
    private(set) var current: Account?
    private var generation = UUID()
    var respondingToRelay: UUID?
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
        center: NotificationCenter, directRestoreClient: InternetAccountClient? = nil,
        account: @escaping () async throws -> Account?
    ) {
        self.store = store
        self.keychain = keychain
        self.namespace = namespace
        self.center = center
        self.directRestoreClient = directRestoreClient
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
        self.model?.callRelationshipSync.resumeDirectRestore = nil
        self.model = model
        if directRestoreClient != nil {
            model?.callRelationshipSync.resumeDirectRestore = { [weak self] in self?.retryDirectRestoreRelayWork() }
        }
        refresh()
    }

    func refreshIfUnavailable() {
        if current == nil && task == nil { refresh() }
    }

    func restore(_ batch: ConfirmedCallRestore, from original: CallRelationshipBackup,
                 completion: SelectedRestoreCompletion? = nil) async throws {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let owner = signer.principal else { throw Failure.accountUnavailable }
        _ = try original.validated(for: owner)
        let checked = try await readCurrentBackup(for: model, as: signer)
        guard let latest = checked.backup, try batch.hasUnchangedCandidates(from: original, in: latest) else {
            throw Failure.backupChanged
        }
        try requireRestoreSelection(completion?.selection, as: checked.signer)
        try model.groupRepository.restoreCallRelationships(
            batch, as: checked.signer, trust: checked.trust, completion: completion?.receipt)
        model.reloadSavedGroups()
    }

    func restoreDirect(
        _ response: DirectCallRestoreResponse, to request: CallRelationshipRestoreRequest,
        for contactID: UUID, from original: CallRelationshipBackup,
        completion: SelectedRestoreCompletion? = nil
    ) async throws {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let owner = signer.principal, let trust = try model.internetSettingsStore.identityTrust() else {
            throw Failure.accountUnavailable
        }
        _ = try original.validated(for: owner)
        guard let contact = original.contacts.first(where: { $0.id == contactID }) else { throw Failure.backupChanged }
        let batch = try response.restoreBatch(for: request, contact: contact,
            localDisplayName: model.localMemberIdentity.displayName, as: signer, verifying: (trust, Date()))
        try await restore(batch, from: original, completion: completion)
    }

    func respondToDirectRestore(_ request: CallRelationshipRestoreRequest) async throws -> DirectCallRestoreResponse? {
        guard let checked = try await directRestoreResponderBackup(for: request),
              let model, let latest = checked.backup else { return nil }
        return try model.groupRepository.sealDirectRestore(
            request, as: checked.signer, trust: checked.trust, now: Date(), matching: latest)
    }

    func directRestoreResponderBackup(for request: CallRelationshipRestoreRequest) async throws -> CurrentBackup? {
        guard let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let trust = try model.internetSettingsStore.identityTrust() else {
            throw Failure.accountUnavailable
        }
        let expected = generation
        guard let requester = try request.verifiedDirectRequester(addressedTo: signer, trust: trust, now: Date()),
              await model.refreshContactDeletionBeforeRestore(requester, addressedTo: signer) else { return nil }
        guard generation == expected else { throw Failure.accountUnavailable }
        return try await readCurrentBackup(for: model, as: signer)
    }

    func readCurrentBackup(for model: IntercomViewModel, as signer: DeviceIdentitySigner) async throws
        -> CurrentBackup {
        guard let cloud = current, let owner = signer.principal else { throw Failure.accountUnavailable }
        let expected = generation
        try await verify(cloud, generation: expected)
        let stored = try await store.load(as: signer, now: Date().timeIntervalSince1970)
        try await verify(cloud, generation: expected)
        guard let active = try model.callRelationshipBackupSigner(),
              active.principal == owner, active.memberID == signer.memberID, active.publicKey == signer.publicKey,
              active.identity?.sessionBinding == signer.identity?.sessionBinding,
              let trust = try model.internetSettingsStore.identityTrust() else { throw Failure.accountUnavailable }
        return .init(backup: stored?.backup, signer: active, trust: trust)
    }

    func readCurrentBackup(scopedTo account: RelayAccount) async throws -> CurrentBackup {
        guard let model else { throw Failure.accountUnavailable }
        let checked = try await readCurrentBackup(for: model, as: account.signer)
        try requireRelayAccount(account)
        return checked
    }

    private func invalidate() {
        generation = UUID()
        current = nil
        task?.cancel()
        task = nil
        directRestorePreparation?.cancel()
        directRestorePreparation = nil
        directRestoreInboxTask?.cancel()
        directRestoreInboxTask = nil
        restoreInboxRun = nil
        restoreInboxNeedsRetry = false
        restoreSelectionCheckpoints = nil
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
        if directRestoreClient != nil {
            restoreSelectionCheckpoints = checkpoints
            retryDirectRestoreRelayWork()
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

extension CloudKitCallRelationshipBackupSession {
    fileprivate enum PendingDirectRestoreState {
        case awaitingResponse
        case applyingResponse
        case restored(receipt: String?)
    }

    final class PendingDirectRestore {
        fileprivate let account: RelayAccount
        fileprivate let contactID: UUID
        fileprivate let backup: CallRelationshipBackup
        fileprivate let request: CallRelationshipRestoreRequest
        fileprivate let submission: DirectCallRestoreRelayPacket.Submission
        fileprivate let selection: CallRelationshipBackupCheckpointStore.RestoreSelection?
        fileprivate var state = PendingDirectRestoreState.awaitingResponse

        var requestDraft: DirectRestoreRequestDraft { .init(request: request, payload: submission.payload) }

        init(
            account: RelayAccount, contactID: UUID, backup: CallRelationshipBackup,
            request: CallRelationshipRestoreRequest, submission: DirectCallRestoreRelayPacket.Submission,
            selection: CallRelationshipBackupCheckpointStore.RestoreSelection? = nil
        ) {
            self.account = account; self.contactID = contactID; self.backup = backup
            self.request = request; self.submission = submission
            self.selection = selection
        }
    }

    struct RelayAccount {
        let generation: UUID
        let access: CallNotificationServiceAccess
        let signer: DeviceIdentitySigner
        let trust: DeviceIdentityTrust
    }

    func prepareRelayedDirectRestore(
        for contactID: UUID, from backup: CallRelationshipBackup, using client: InternetAccountClient
    ) async throws -> PendingDirectRestore? {
        let account = try relayAccount()
        guard let prepared = try await prepareDirectRestore(for: contactID, from: backup, using: client)
        else { return nil }
        try requireRelayAccount(account)
        let submission = try DirectCallRestoreRelayPacket.seal(
            .request(value: prepared.request), to: prepared.recipient, as: account.signer, now: Date())
        return .init(account: account, contactID: contactID, backup: backup, request: prepared.request,
                     submission: submission)
    }

    func sendRelayedDirectRestore(_ pending: PendingDirectRestore, using client: InternetAccountClient) async throws {
        try requireRelayAccount(pending.account)
        guard case .awaitingResponse = pending.state, let model else { return }
        _ = try await checkDirectRestoreContact(
            pending.contactID, from: pending.backup, for: model, as: pending.account.signer)
        try requireRelayAccount(pending.account)
        try requireRestoreSelection(pending.selection, as: pending.account.signer)
        let now = Date()
        guard pending.request.expiresAt > now,
              Double(pending.submission.payload.expiresAt) > now.timeIntervalSince1970 * 1_000
        else { throw Failure.requestExpired }
        try await client.submitDirectRestorePacket(pending.submission, access: pending.account.access)
    }

    func finishRelayedDirectRestore(_ pending: PendingDirectRestore, using client: InternetAccountClient)
        async throws -> Bool {
        try requireRelayAccount(pending.account)
        switch pending.state {
        case .applyingResponse:
            return false
        case .restored(let receipt):
            await finishRestoreReceipt(receipt, for: pending, using: client)
            return true
        case .awaitingResponse:
            try requireRestoreSelection(pending.selection, as: pending.account.signer)
            pending.state = .applyingResponse
        }
        defer { if case .applyingResponse = pending.state { pending.state = .awaitingResponse } }
        let account = pending.account
        let inbox = try await client.directRestoreInbox(access: account.access)
        try requireRelayAccount(account)
        for packet in inbox {
            guard let response = try? packet.openResponse(
                for: pending.request, as: account.signer, trust: account.trust, now: Date()) else { continue }
            let completion = try pending.selection.map { selection in
                try SelectedRestoreCompletion(selection, response: packet, in: account)
            }
            try await restoreDirect(response, to: pending.request, for: pending.contactID, from: pending.backup,
                                    completion: completion)
            pending.state = .restored(receipt: packet.id)
            await finishRestoreReceipt(packet.id, for: pending, using: client)
            return true
        }
        return false
    }

    private func finishRestoreReceipt(_ id: String?, for pending: PendingDirectRestore,
                                      using client: InternetAccountClient) async {
        if pending.selection != nil {
            _ = await resumeCompletedDirectRestore(in: pending.account, using: client)
            return
        }
        guard let id, (try? requireRelayAccount(pending.account)) != nil else { return }
        do {
            try await client.retireDirectRestorePacket(id, access: pending.account.access)
            pending.state = .restored(receipt: nil)
        } catch {
            // Local restore is already committed. Retry only the receipt cleanup.
        }
    }

    func relayAccount() throws -> RelayAccount {
        guard !Task.isCancelled, let model, current != nil, let signer = try model.callRelationshipBackupSigner(),
              let access = try model.internetSettingsStore.notificationAccess(memberID: signer.memberID),
              let trust = try model.internetSettingsStore.identityTrust(), signer.principal == access.principal
        else { throw Failure.accountUnavailable }
        return .init(generation: generation, access: access, signer: signer, trust: trust)
    }

    func requireRelayAccount(_ expected: RelayAccount) throws {
        let current = try relayAccount()
        guard current.generation == expected.generation, current.access == expected.access,
              current.signer.publicKey == expected.signer.publicKey,
              current.signer.memberID == expected.signer.memberID,
              current.signer.identity?.sessionBinding == expected.signer.identity?.sessionBinding,
              current.trust.issuerKey == expected.trust.issuerKey
        else { throw Failure.accountUnavailable }
    }
}

extension CallRelationshipBackup {
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
