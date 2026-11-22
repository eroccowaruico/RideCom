import CloudKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CloudKitCallRelationshipBackupStoreTests {
    @Test func replacementReadsTheSameAccountAndOnlyTheEncryptedCandidateFields() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let previous = try signer(from: fixture.peer("old", account: "a"))
        let replacement = try signer(from: fixture.peer("new", account: "a"))
        let different = try signer(from: fixture.peer("other", account: "b"))
        let records = MemoryCallBackupRecords()
        let store = records.store
        let now = Date().timeIntervalSince1970
        let id = UUID()
        let data = try payload(for: previous, groupID: id, extraField: true)
        let candidate = try JSONDecoder().decode(CallRelationshipBackup.self, from: data)

        #expect(try await store.load(as: previous, now: now) == nil)
        let saved = try await store.save(candidate, replacing: nil, as: previous, now: now)
        let restored = try #require(try await store.load(as: replacement, now: now))
        #expect(restored.backup == saved.backup)
        #expect(restored.backup.groups.map(\.id) == [id])
        #expect(try await store.load(as: different, now: now) == nil)

        let record = try #require(records.current)
        #expect(record["payload"] == nil)
        let encrypted = try #require(record.encryptedValues["payload"] as? Data)
        let fields = try #require(JSONSerialization.jsonObject(with: encrypted) as? [String: Any])
        #expect(Set(fields.keys) == ["version", "owner", "groups", "contacts"])
        #expect(records.savePolicies == [.ifServerRecordUnchanged])

        await #expect(throws: GroupStorageError.identityConflict) {
            _ = try await store.save(candidate, replacing: nil, as: different, now: now)
        }
        let other = try backup(for: different, groupID: id)
        await #expect(throws: CloudKitCallRelationshipBackupStore.Failure.invalidRecord) {
            _ = try await store.save(other, replacing: saved, as: different, now: now)
        }
        var invalid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        invalid["version"] = 2
        let invalidBackup = try JSONDecoder().decode(CallRelationshipBackup.self,
            from: JSONSerialization.data(withJSONObject: invalid))
        await #expect(throws: GroupStorageError.invalidUpdate) {
            _ = try await store.save(invalidBackup, replacing: saved, as: previous, now: now)
        }
        #expect(records.savePolicies.count == 1)
    }

    @Test func conflictAndReadFailurePreserveTheExistingRecord() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let owner = try signer(from: fixture.peer("owner", account: "a"))
        let records = MemoryCallBackupRecords()
        let store = records.store
        let now = Date().timeIntervalSince1970
        let id = UUID()
        let original = try await store.save(backup(for: owner, groupID: id), replacing: nil, as: owner, now: now)
        let changed = try backup(for: owner, groupID: id, name: "Second group name")
        records.writeError = CKError(.serverRecordChanged)
        await #expect(throws: CKError.self) {
            try await store.save(changed, replacing: original, as: owner, now: now)
        }
        #expect(try await store.load(as: owner, now: now)?.backup == original.backup)
        #expect(records.savePolicies == [.ifServerRecordUnchanged, .ifServerRecordUnchanged])

        records.readError = CKError(.zoneNotFound)
        await #expect(throws: CKError.self) {
            try await store.load(as: owner, now: now)
        }
        #expect(records.savePolicies.count == 2)

        records.readError = nil
        records.writeError = nil
        let updated = try await store.save(changed, replacing: original, as: owner, now: now)
        #expect(updated.backup.groups.first?.name == "Second group name")
        #expect(try await store.load(as: owner, now: now)?.backup == updated.backup)
    }

    @Test func plaintextAndEmptyPayloadCannotReplaceAnUnreadableBackup() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let owner = try signer(from: fixture.peer("owner", account: "a"))
        let records = MemoryCallBackupRecords()
        let store = records.store
        let now = Date().timeIntervalSince1970
        let data = try payload(for: owner, groupID: UUID())
        let original = try await store.save(JSONDecoder().decode(CallRelationshipBackup.self, from: data),
                                            replacing: nil, as: owner, now: now)
        let record = try #require(records.current)
        record["unexpected"] = "Fixture field" as NSString
        await #expect(throws: CloudKitCallRelationshipBackupStore.Failure.invalidRecord) {
            try await store.load(as: owner, now: now)
        }
        record["unexpected"] = nil
        record.encryptedValues["payload"] = nil
        record["payload"] = data as NSData

        await #expect(throws: CloudKitCallRelationshipBackupStore.Failure.invalidRecord) {
            try await store.load(as: owner, now: now)
        }
        let empty = try backup(for: owner, groupID: nil)
        await #expect(throws: CloudKitCallRelationshipBackupStore.Failure.nothingToSave) {
            try await store.save(empty, replacing: original, as: owner, now: now)
        }
        #expect(records.savePolicies.count == 1)
    }

    private func signer(from peer: AppTestSupport.Harness) throws -> DeviceIdentitySigner {
        let model = peer.viewModel
        return try model.internetSettingsStore.invitationSigner(memberID: model.localMemberIdentity.memberID)
    }

    private func backup(for signer: DeviceIdentitySigner, groupID: UUID?, name: String = "Riders") throws
        -> CallRelationshipBackup {
        try JSONDecoder().decode(CallRelationshipBackup.self, from: payload(for: signer, groupID: groupID, name: name))
    }

    private func payload(
        for signer: DeviceIdentitySigner, groupID: UUID?, name: String = "Riders", extraField: Bool = false
    ) throws -> Data {
        let owner = try #require(signer.principal)
        let groups = groupID.map { [["id": $0.uuidString, "name": name]] } ?? []
        var json: [String: Any] = [
            "version": 1, "owner": ["issuer": owner.issuer, "userID": owner.userID],
            "groups": groups, "contacts": []
        ]
        if extraField { json["unexpected"] = "Fixture field" }
        return try JSONSerialization.data(withJSONObject: json)
    }
}

@MainActor @Suite(.serialized)
struct CallRelationshipAutomaticBackupTests {
    @Test func localCommitAutomaticallyBacksUpAndFailedCommitDoesNotWrite() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let peer = try fixture.peer("rider", account: "a")
        let model = peer.viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints()) { cloudAccount() }
        let sync = try #require(model.callRelationshipBackupSync)
        await sync.task?.value
        #expect(sync.status == .saved)
        #expect(records.savePolicies.count == 1)

        #expect(model.renameGroup(id, to: "New group name"))
        await sync.task?.value
        #expect(records.savePolicies.count == 2)
        let saved = try await storedBackup(in: records, for: model)
        #expect(saved?.groups.first?.name == "New group name")

        peer.groupStore.failSaving = true
        #expect(!model.renameGroup(id, to: "Uncommitted name"))
        #expect(sync.task == nil)
        #expect(records.savePolicies.count == 2)
    }

    @Test func separatelyEditedCloudRecordIsPreservedAcrossAConflictAndRestart() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let model = try fixture.peer("rider", account: "a").viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        let store = records.store
        let storeForCheckpoints = checkpoints()
        model.configureCallRelationshipBackup(store: store, checkpoints: storeForCheckpoints) { cloudAccount() }
        let first = try #require(model.callRelationshipBackupSync)
        await first.task?.value
        #expect(first.status == .saved)

        let signer = try model.internetSettingsStore.invitationSigner(memberID: "rider")
        let now = Date().timeIntervalSince1970
        let initial = try #require(try await store.load(as: signer, now: now))
        let data = try JSONEncoder().encode(initial.backup)
        let text = try #require(String(data: data, encoding: .utf8))
        let edit = text.replacingOccurrences(of: "Original name", with: "Cloud edit")
        let edited = try JSONDecoder().decode(CallRelationshipBackup.self, from: Data(edit.utf8))
        _ = try await store.save(edited, replacing: initial, as: signer, now: now)
        #expect(model.renameGroup(id, to: "Local edit"))
        await first.task?.value
        #expect(first.status == .requiresReconciliation)

        model.configureCallRelationshipBackup(store: store, checkpoints: storeForCheckpoints) { cloudAccount() }
        let next = try #require(model.callRelationshipBackupSync)
        await next.task?.value
        #expect(next.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 2)
        let saved = try await storedBackup(in: records, for: model)
        #expect(saved?.groups.first?.name == "Cloud edit")

        records.current = nil
        next.request()
        await next.task?.value
        #expect(next.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 2)
    }

    @Test func foregroundRetriesAFailedWriteAndAccountSwitchStopsANewWrite() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let model = try fixture.peer("rider", account: "a").viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        records.readError = CKError(.networkUnavailable)
        var activeCloudAccount = cloudAccount()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints()) {
            activeCloudAccount
        }
        let sync = try #require(model.callRelationshipBackupSync)
        await sync.task?.value
        #expect(sync.status == .retryPending)
        #expect(records.savePolicies.isEmpty)

        records.readError = nil
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil))
        app.systemSurfaceIsForeground = true
        await sync.task?.value
        #expect(sync.status == .saved)
        #expect(records.savePolicies.count == 1)

        records.onRead = { activeCloudAccount = cloudAccount("other") }
        #expect(model.renameGroup(id, to: "Pending edit"))
        await sync.task?.value
        #expect(sync.status == .idle)
        #expect(records.savePolicies.count == 1)
    }

    @Test func commitDuringReadQueuesTheLatestSnapshotAndDeletingTheLastGroupDoesNotUploadEmpty() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let model = try fixture.peer("rider", account: "a").viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        records.onRead = { [weak records] in
            records?.onRead = nil
            #expect(model.renameGroup(id, to: "Latest name"))
        }
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints()) { cloudAccount() }
        let sync = try #require(model.callRelationshipBackupSync)
        #expect(sync.status == .pending)
        await sync.task?.value
        #expect(records.savePolicies.count == 1)
        let saved = try await storedBackup(in: records, for: model)
        #expect(saved?.groups.first?.name == "Latest name")

        #expect(model.commitGroups([]))
        await sync.task?.value
        #expect(sync.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 1)
    }

    @Test func restartUsesTheLastAcknowledgedBackupAndKeepsAChangedCloudAccountSeparate() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let peer = try fixture.peer("rider", account: "a")
        let model = peer.viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        let keychain = DictionaryKeychain()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints(keychain: keychain)) {
            cloudAccount()
        }
        await model.callRelationshipBackupSync?.task?.value
        #expect(records.savePolicies.count == 1)
        model.stopCallRelationshipBackup()
        #expect(model.renameGroup(id, to: "Edited while offline"))

        let replacement = try fixture.peer("replacement", account: "a").viewModel
        let differentKey = try replacement.internetSettingsStore.invitationSigner(memberID: "replacement")
        #expect(try checkpoints(keychain: keychain).load(as: differentKey) == nil)

        let restarted = try fixture.restart(peer).viewModel
        let wrongAccount = checkpoints(keychain: keychain, cloudAccount: "other")
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: wrongAccount) {
            cloudAccount("other")
        }
        await restarted.callRelationshipBackupSync?.task?.value
        #expect(restarted.callRelationshipBackupSync?.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 1)

        let sameAccount = checkpoints(keychain: keychain)
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: sameAccount) { cloudAccount() }
        await restarted.callRelationshipBackupSync?.task?.value
        #expect(restarted.callRelationshipBackupSync?.status == .saved)
        #expect(records.savePolicies.count == 2)
        let saved = try await storedBackup(in: records, for: restarted)
        #expect(saved?.groups.first?.name == "Edited while offline")
    }

    @Test func completedWriteWithALostResponseCanBeFollowedByANewerEditAfterRestart() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let peer = try fixture.peer("rider", account: "a")
        let model = peer.viewModel
        let id = try addOwnedGroup(to: model)
        let records = MemoryCallBackupRecords()
        let keychain = DictionaryKeychain()
        let first = checkpoints(keychain: keychain)
        records.postWriteError = CKError(.networkFailure)
        model.configureCallRelationshipBackup(store: records.store, checkpoints: first) { cloudAccount() }
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .retryPending)
        #expect(records.savePolicies.count == 1)
        model.stopCallRelationshipBackup()
        #expect(model.renameGroup(id, to: "Latest change"))

        records.postWriteError = nil
        let restarted = try fixture.restart(peer).viewModel
        let checkpointStore = checkpoints(keychain: keychain)
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: checkpointStore) { cloudAccount() }
        await restarted.callRelationshipBackupSync?.task?.value
        #expect(restarted.callRelationshipBackupSync?.status == .saved)
        #expect(records.savePolicies.count == 2)
        let saved = try await storedBackup(in: records, for: restarted)
        #expect(saved?.groups.first?.name == "Latest change")
    }

    private func checkpoints(
        keychain: KeychainSecretStoring = DictionaryKeychain(), cloudAccount: String = "owner"
    ) -> CallRelationshipBackupCheckpointStore {
        .init(keychain: keychain, namespace: "fixture",
              cloud: self.cloudAccount(cloudAccount))
    }

    private func cloudAccount(_ name: String = "owner") -> CallRelationshipBackupCheckpointStore.CloudAccount {
        .init(container: "fixture", environment: .development, account: name)
    }

    private func addOwnedGroup(to model: IntercomViewModel) throws -> UUID {
        let id = UUID()
        let member = model.localMemberIdentity.memberID
        let signer = try model.internetSettingsStore.invitationSigner(memberID: member)
        let binding = AccountDeviceBinding(principal: try #require(signer.principal), publicKey: signer.publicKey)
        let group = try IntercomGroup(id: id, name: "Original name", members: [.init(id: member, displayName: "Rider")],
                                      accountDevices: [member: binding])
        try #require(model.commitGroups([group]))
        return id
    }

    private func storedBackup(in records: MemoryCallBackupRecords, for model: IntercomViewModel) async throws
        -> CallRelationshipBackup? {
        let signer = try model.internetSettingsStore.invitationSigner(memberID: model.localMemberIdentity.memberID)
        return try await records.store.load(as: signer, now: Date().timeIntervalSince1970)?.backup
    }
}

@MainActor
final class MemoryCallBackupRecords {
    var current: CKRecord?
    var savePolicies: [CKModifyRecordsOperation.RecordSavePolicy] = []
    var readError: CKError?
    var writeError: CKError?
    var postWriteError: CKError?
    var onRead: (() -> Void)?

    var store: CloudKitCallRelationshipBackupStore {
        .init(fetch: { id in
            if let error = self.readError { throw error }
            self.onRead?()
            guard let current = self.current, current.recordID == id else { throw CKError(.unknownItem) }
            return current
        }, write: { record, policy in
            self.savePolicies.append(policy)
            if let error = self.writeError { throw error }
            self.current = record
            if let error = self.postWriteError { throw error }
            return record
        })
    }
}
