import CloudKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CallRelationshipBackupRemovalTests {
    enum ConcurrentSave: CaseIterable, Sendable {
        case groupEdited, contactReregistered, groupsRemoved, replyLost, writeConflict
    }

    @Test(arguments: ConcurrentSave.allCases)
    func removingAContactPreservesConcurrentCloudChanges(change: ConcurrentSave) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let source = try fixture.peer("rider", account: "a")
        let companion = try fixture.peer("companion", account: "b")
        let writer = try fixture.peer("another-device", account: "a")
        let model = source.viewModel
        for device in [source, companion] { device.viewModel.allowsNearbyGroupDelivery = false }
        _ = try fixture.completeGroupContactRegistration(from: source, to: companion)
        model.groupDeliveryClient = nil
        let person = try #require(model.savedRemoteUsers.first?.id)
        try #require(model.selectUser(person, connectIfIdle: false))
        let groupID = try addGroup(to: model)
        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value
        model.stopCallRelationshipBackup()

        let signer = try writer.viewModel.internetSettingsStore.invitationSigner(memberID: "another-device")
        let now = Date().timeIntervalSince1970
        let earlier = try #require(try await records.store.load(as: signer, now: now))
        let edited = try concurrentBackup(from: earlier.backup, groupID: groupID, change: change)
        _ = try await records.store.save(edited, replacing: earlier, as: signer, now: now)
        try #require(model.removeSavedUser(person))
        source.groupStore.snapshot = try GroupSnapshot.decode(source.groupStore.snapshot.encoded())

        let restarted = try fixture.restart(source).viewModel
        records.postWriteError = change == .replyLost ? CKError(.networkFailure) : nil
        records.writeError = change == .writeConflict ? CKError(.serverRecordChanged) : nil
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await restarted.callRelationshipBackupSync?.task?.value
        if change == .replyLost || change == .writeConflict {
            #expect(restarted.callRelationshipBackupSync?.status == .retryPending)
            records.postWriteError = nil
            records.writeError = nil
        }
        if change == .writeConflict {
            #expect(try await records.store.load(as: signer, now: now)?.backup == edited)
        }
        restarted.callRelationshipBackupSync?.request()
        await restarted.callRelationshipBackupSync?.task?.value

        let merged = try #require(try await records.store.load(as: signer, now: now)).backup
        #expect(merged.groups == edited.groups)
        #expect(merged.contacts == (change == .contactReregistered ? edited.contacts : []))
        let attempts = change == .contactReregistered ? 2 : 3
        #expect(records.savePolicies.count == attempts + (change == .writeConflict ? 1 : 0))
        #expect(records.savePolicies.allSatisfy { $0 == .ifServerRecordUnchanged })
        #expect(restarted.callRelationshipBackupSync?.status == .requiresReconciliation)
        #expect(restarted.groups.first { $0.id == groupID }?.name == "Riders")
        #expect(restarted.savedRemoteUsers.isEmpty)
    }

    private func concurrentBackup(from earlier: CallRelationshipBackup, groupID: UUID, change: ConcurrentSave) throws
        -> CallRelationshipBackup {
        let data = try JSONEncoder().encode(earlier)
        var payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var groups = try #require(payload["groups"] as? [[String: Any]])
        var contacts = try #require(payload["contacts"] as? [[String: Any]])
        try #require(contacts.count == 1)
        _ = try #require(contacts[0]["confirmedRegistrationID"])
        let group = try #require(groups.firstIndex { $0["id"] as? String == groupID.uuidString })
        switch change {
        case .groupEdited, .replyLost, .writeConflict: groups[group]["name"] = "Other edit"
        case .contactReregistered: contacts[0]["confirmedRegistrationID"] = UUID().uuidString
        case .groupsRemoved: groups = []
        }
        payload["groups"] = groups
        payload["contacts"] = contacts
        return try JSONDecoder().decode(CallRelationshipBackup.self,
                                        from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test(arguments: [false, true])
    func removingTheLastRelationshipEmptiesTheKnownBackupAfterRestart(contact: Bool) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let source = try fixture.peer("rider", account: "a")
        let model = source.viewModel
        let remove: () -> Bool
        if contact {
            let other = try fixture.peer("companion", account: "b")
            model.allowsNearbyGroupDelivery = false
            other.viewModel.allowsNearbyGroupDelivery = false
            _ = try fixture.completeGroupContactRegistration(from: source, to: other)
            let person = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.selectUser(person, connectIfIdle: false))
            try #require(model.commitGroups(model.groups.filter { $0.kind == .direct }))
            remove = { model.removeSavedUser(person) }
        } else {
            let id = try addGroup(to: model)
            remove = { model.deleteGroup(id) }
        }

        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value
        #expect(records.savePolicies.count == 1)
        model.stopCallRelationshipBackup()
        try #require(remove())
        let data = try JSONEncoder().encode(source.groupStore.snapshot)
        source.groupStore.snapshot = try JSONDecoder().decode(GroupSnapshot.self, from: data)

        let restarted = try fixture.restart(source).viewModel
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await restarted.callRelationshipBackupSync?.task?.value
        #expect(restarted.callRelationshipBackupSync?.status == .saved)
        #expect(records.savePolicies == [.ifServerRecordUnchanged, .ifServerRecordUnchanged])
        let signer = try restarted.internetSettingsStore.invitationSigner(memberID: "rider")
        let saved = try await records.store.load(as: signer, now: Date().timeIntervalSince1970)
        #expect(saved?.backup.isEmpty == true)
    }

    @Test func anotherDevicesEditIsKeptWhenTheLastGroupIsRemoved() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let model = try fixture.peer("rider", account: "a").viewModel
        let id = try addGroup(to: model)
        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value
        let signer = try model.internetSettingsStore.invitationSigner(memberID: "rider")
        let now = Date().timeIntervalSince1970
        let before = try #require(try await records.store.load(as: signer, now: now))
        let data = try JSONEncoder().encode(before.backup)
        let original = try #require(String(bytes: data, encoding: .utf8))
        let edited = original.replacingOccurrences(of: "Riders", with: "Other edit")
        let candidate = try JSONDecoder().decode(CallRelationshipBackup.self, from: Data(edited.utf8))
        _ = try await records.store.save(candidate, replacing: before, as: signer, now: now)

        try #require(model.deleteGroup(id))
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 2)
        #expect(try await records.store.load(as: signer, now: now)?.backup == candidate)
    }

    @Test(arguments: [false, true])
    func consecutiveExplicitRemovalsCanClearTheBackup(intermediateSave: Bool) async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let source = try fixture.peer("rider", account: "a")
        let model = source.viewModel
        let first = try addGroup(to: model)
        let second = try addGroup(to: model)
        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value

        if !intermediateSave { model.stopCallRelationshipBackup() }
        try #require(model.deleteGroup(first))
        await model.callRelationshipBackupSync?.task?.value
        model.stopCallRelationshipBackup()
        #expect(records.savePolicies.count == (intermediateSave ? 2 : 1))
        source.groupStore.snapshot = try JSONDecoder().decode(
            GroupSnapshot.self, from: JSONEncoder().encode(source.groupStore.snapshot))

        let restarted = try fixture.restart(source).viewModel
        try #require(restarted.deleteGroup(second))
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await restarted.callRelationshipBackupSync?.task?.value
        let signer = try restarted.internetSettingsStore.invitationSigner(memberID: "rider")
        #expect(restarted.callRelationshipBackupSync?.status == .saved)
        #expect(try await records.store.load(as: signer, now: Date().timeIntervalSince1970)?.backup.isEmpty == true)
    }

    @Test func aGenericEmptyUpdateCannotFinishAnIncompleteSeriesOfRemovals() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let model = try fixture.peer("rider", account: "a").viewModel
        let first = try addGroup(to: model)
        _ = try addGroup(to: model)
        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value
        model.stopCallRelationshipBackup()

        try #require(model.deleteGroup(first))
        try #require(model.commitGroups([]))
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .requiresReconciliation)
        #expect(records.savePolicies.count == 1)
    }

    @Test func removalWithLostResponseIsAcknowledgedAfterRestartWithoutASecondWrite() async throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let source = try fixture.peer("rider", account: "a")
        let model = source.viewModel
        let id = try addGroup(to: model)
        let records = MemoryCallBackupRecords()
        let checkpoints = checkpoints()
        model.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await model.callRelationshipBackupSync?.task?.value

        records.postWriteError = CKError(.networkFailure)
        try #require(model.deleteGroup(id))
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .retryPending)
        #expect(records.savePolicies.count == 2)
        model.stopCallRelationshipBackup()

        records.postWriteError = nil
        let restarted = try fixture.restart(source).viewModel
        restarted.configureCallRelationshipBackup(store: records.store, checkpoints: checkpoints) { checkpoints.cloud }
        await restarted.callRelationshipBackupSync?.task?.value
        #expect(restarted.callRelationshipBackupSync?.status == .saved)
        #expect(records.savePolicies.count == 2)
    }

    private func checkpoints() -> CallRelationshipBackupCheckpointStore {
        .init(keychain: DictionaryKeychain(), namespace: "RemovalFixture",
              cloud: .init(container: "fixture", environment: .development, account: "owner"))
    }

    private func addGroup(to model: IntercomViewModel) throws -> UUID {
        let id = UUID()
        let signer = try model.internetSettingsStore.invitationSigner(memberID: "rider")
        let principal = try #require(signer.principal)
        let binding = AccountDeviceBinding(principal: principal, publicKey: signer.publicKey)
        let group = try IntercomGroup(id: id, name: "Riders", members: [.init(id: "rider", displayName: "Rider")],
                                      accountDevices: ["rider": binding])
        try #require(model.commitGroups(model.groups + [group]))
        return id
    }
}
