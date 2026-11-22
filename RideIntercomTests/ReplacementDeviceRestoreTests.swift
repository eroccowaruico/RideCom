import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CallRelationshipBackupTests {
    @Test func backupRoundTripContainsOnlyTheOwnersCallCandidates() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore()
        var snapshot = scenario.backup
        let oldSigner = scenario.oldSigner
        let foreign = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        let groupIndex = try #require(snapshot.groups.firstIndex { $0.id == scenario.groupID })
        snapshot.groups[groupIndex].accountDevices[oldSigner.memberID] = scenario.backupOwner
        snapshot.groups.append(.init(try IntercomGroup(name: "Unknown owner", members: [
            .init(id: oldSigner.memberID, displayName: "Rider")
        ])))
        let foreignBinding = AccountDeviceBinding(
            principal: try #require(foreign.principal), publicKey: foreign.publicKey)
        snapshot.groups.append(.init(try IntercomGroup(
            name: "Other owner", members: [.init(id: oldSigner.memberID, displayName: "Rider")],
            accountDevices: [oldSigner.memberID: foreignBinding])))
        snapshot.synchronizeUserReferences()
        store.snapshot = snapshot
        let repository = GroupRepository(store: store, credentials: scenario.restoredCredentials)
        _ = try repository.load(localMemberID: oldSigner.memberID)
        let now = Date().timeIntervalSince1970
        let candidate = try repository.callRelationshipBackup(as: oldSigner, now: now)
        let data = try JSONEncoder().encode(candidate)
        let newSigner = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let restored = try CallRelationshipBackup.read(data, as: newSigner, now: now)

        #expect(restored == candidate)
        #expect(restored.owner == scenario.backupOwner.principal)
        #expect(restored.groups.map(\.id) == [scenario.groupID])
        #expect(restored.contacts.map(\.id) == [scenario.savedPersonID])
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(payload.keys) == ["version", "owner", "groups", "contacts"])
        let group = try #require((payload["groups"] as? [[String: Any]])?.first)
        #expect(Set(group.keys) == ["id", "name"])
        let contact = try #require((payload["contacts"] as? [[String: Any]])?.first)
        #expect(Set(contact.keys) == ["id", "principal", "restoreRecipientFingerprint"])
        let fingerprint = try #require(contact["restoreRecipientFingerprint"] as? String)
        #expect(IdentityEncoding.decode(fingerprint)?.count == 32)
        #expect(throws: GroupStorageError.identityConflict) {
            try CallRelationshipBackup.read(data, as: foreign, now: now)
        }
        let expiry = try #require(newSigner.identity?.expiresAt)
        #expect(throws: GroupStorageError.identityConflict) {
            try CallRelationshipBackup.read(data, as: newSigner, now: expiry)
        }

        var unknownVersion = payload
        unknownVersion["version"] = 2
        let unknownData = try JSONSerialization.data(withJSONObject: unknownVersion)
        #expect(throws: GroupStorageError.invalidUpdate) {
            try CallRelationshipBackup.read(unknownData, as: newSigner, now: now)
        }
    }

    @Test func backupRejectsAStaleSnapshotAfterAnotherProcessChangesIt() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore()
        store.snapshot = scenario.backup
        let repository = GroupRepository(store: store, credentials: scenario.restoredCredentials)
        let signer = scenario.oldSigner
        _ = try repository.load(localMemberID: signer.memberID)
        store.snapshot.generation = UUID()
        let now = Date().timeIntervalSince1970

        #expect(throws: GroupStorageError.changedByAnotherProcess) {
            try repository.callRelationshipBackup(as: signer, now: now)
        }
        #expect(repository.writableSnapshot == nil)
    }
}

@MainActor @Suite(.serialized)
struct ReplacementDeviceRestoreTests {
    @Test(arguments: [false, true])
    func restoreRejectsAContactDeviceOutsideTheConfirmedDirectCall(addDevice: Bool) throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        _ = try repository.load(localMemberID: "alice")
        let original = store.snapshot
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let batch = try scenario.confirmedRestore()
        var contact = try #require(batch.users.first)
        let originalDeviceID = try #require(contact.memberIDs.first)
        let extraDevice = try scenario.fixture.peer("bob-extra", account: "b").viewModel
            .internetSettingsStore.invitationSigner(memberID: "bob-extra")
        if addDevice { contact.memberIDs.append(extraDevice.memberID) }
        contact.deviceKeys?[addDevice ? extraDevice.memberID : originalDeviceID] = extraDevice.publicKey
        let unconfirmed = ConfirmedCallRestore(owner: batch.owner, previousMemberID: batch.previousMemberID,
                                               users: [contact], calls: batch.calls)

        #expect(throws: GroupStorageError.invalidUpdate) {
            try repository.restoreCallRelationships(unconfirmed, as: signer, trust: scenario.trust)
        }
        #expect(store.snapshot == original)
        #expect(credentials.values.isEmpty)
    }

    @Test func aBackupWithTheOldMemberIDCannotBeOpenedByTheReplacement() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore()
        store.snapshot = scenario.backup
        let repository = GroupRepository(store: store, credentials: scenario.restoredCredentials)

        #expect(throws: IntercomGroupError.invalidStoredGroups) {
            _ = try repository.load(localMemberID: "alice")
        }
        #expect(store.snapshot == scenario.backup)
        #expect(repository.writableSnapshot == nil)
    }

    @Test func restoredSettingsWithoutDeviceKeysDoNotResumeCallsOrInvitations() async throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let account = AccountFixture(); defer { account.remove() }
        let deviceKeys = DictionaryKeychain()
        let callKeys = InMemoryGroupCredentialStore()
        let internet = InternetConnectionSettingsStore(keychain: deviceKeys, namespace: account.name)
        let store = InMemoryGroupStore()
        let person = try #require(scenario.backup.users.first { $0.id == scenario.savedPersonID })
        let peerID = try #require(person.memberIDs.first)
        let queuedDelivery = GroupDeliveryRecord(
            groupID: scenario.groupID, recipient: try #require(person.principal), recipientMemberID: peerID,
            recipientKey: try #require(person.deviceKeys?[peerID]),
            expiresAt: Date().addingTimeInterval(GroupDeliveryRecord.invitationLifetime).timeIntervalSince1970,
            state: .queued, credentialReference: UUID())
        store.snapshot = scenario.backup
        store.snapshot.groupDeliveries = [queuedDelivery]
        let original = store.snapshot
        account.defaults.set("alice-old", forKey: "RideIntercom.localMemberID")
        account.defaults.set("Alice", forKey: "RideIntercom.localDisplayName")
        let restoredIdentity = UserDefaultsLocalMemberIdentityStore(defaults: account.defaults).loadOrCreate()

        #expect(IntercomViewModel.makeForCurrentProcess(accountSession: account.session) == nil)
        account.signIn()
        let harness = AppTestSupport.makeHarness(
            accountSession: account.session, groups: [], groupStore: store, credentialStore: callKeys,
            internetSettingsStore: internet, localMemberID: restoredIdentity.memberID)
        let model = harness.viewModel
        model.groupDeliveryClient = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        model.allowsNearbyGroupDelivery = false
        model.setRTCTransportRoutes([.multipeer, .webRTC])
        #expect(model.canStartCalls)
        #expect(Set(model.groups.map(\.id)) == [scenario.groupID, scenario.directID])
        #expect(model.groupRepository.groupDeliveries == [queuedDelivery])
        #expect(!model.startCall(to: .group(scenario.groupID), accountAccessID: model.accountAccessID))
        #expect(model.makeSelectedGroupInviteURL() == nil)
        #expect(!model.startCall(to: .user(scenario.savedPersonID), accountAccessID: model.accountAccessID))
        #expect(harness.callSession.connectedGroup == nil)
        #expect(harness.callSession.startMediaCallCount == 0)
        #expect(model.nearbyGroupDeliveryCredentials().isEmpty)
        #expect(try internet.loadIdentity(memberID: restoredIdentity.memberID) == nil)
        #expect(deviceKeys.accounts(service: account.name + ".InternetConnection").isEmpty)
        #expect(callKeys.values.isEmpty)
        #expect(store.snapshot == original)
    }

    @Test(arguments: [false, true])
    func existingCallAcceptsTheReplacementAfterRestoringItsLocalMembership(groupCall: Bool) async throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let replacement = try scenario.openReboundSnapshot()
        defer { replacement.viewModel.disconnect() }
        let other = scenario.other
        let restored = replacement.viewModel, unchanged = other.viewModel
        let restoredPerson = try #require(restored.savedRemoteUsers.first)
        let otherPerson = try #require(unchanged.savedRemoteUsers.first)
        let callID = groupCall ? scenario.groupID : scenario.directID
        try #require(restored.groupStorageIssue == nil)
        try #require(restoredPerson.id == scenario.savedPersonID)
        try #require(restored.startCall(
            to: groupCall ? .group(callID) : .user(restoredPerson.id), accountAccessID: restored.accountAccessID))
        try #require(unchanged.startCall(
            to: groupCall ? .group(callID) : .user(otherPerson.id), accountAccessID: unchanged.accountAccessID))
        try #require(restored.activeGroupID == callID && unchanged.activeGroupID == callID)
        let keysMatch = try restored.groupRepository.credential(for: callID)
            == unchanged.groupRepository.credential(for: callID)
        try #require(keysMatch)
        other.callSession.authenticate(["alice"]); replacement.callSession.authenticate(["bob"])
        if !groupCall {
            try scenario.fixture.deliverProfile(from: replacement, to: other, certified: false)
            #expect(unchanged.callAccessAdmittedMemberships.isEmpty)
            let different = try scenario.fixture.peer("different-person", account: "c")
            other.callSession.authenticate(["alice", "different-person"])
            try scenario.fixture.deliverProfile(from: different, to: other)
            #expect(unchanged.callAccessAdmittedMemberships.isEmpty)
        }
        try scenario.fixture.deliverProfile(from: replacement, to: other)
        try scenario.fixture.deliverProfile(from: other, to: replacement)
        #expect(unchanged.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["alice"])
        #expect(restored.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["bob"])
        if groupCall {
            let group = try #require(unchanged.groupRepository.storedGroup(callID))
            #expect(Set(group.members.map(\.id)) == ["alice", "bob"])
        }
        other.callSession.authenticate([]); other.callSession.authenticate(["alice"])
        try scenario.fixture.deliverProfile(from: replacement, to: other, certified: false)
        #expect(unchanged.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["alice"])
        #if os(iOS)
        try await DirectCallTests.assertLocalCall(
            aliceGroup: try #require(replacement.callSession.connectedGroup),
            bobGroup: try #require(other.callSession.connectedGroup))
        #endif
    }

    @Test func aNewDeviceForAnExcludedAccountIsRefusedEvenWithTheOldSnapshot() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let replacement = try scenario.openReboundSnapshot()
        defer { replacement.viewModel.disconnect() }
        let other = scenario.other, groupID = scenario.groupID
        let model = other.viewModel
        try #require(model.removeMember("alice-old", from: groupID))
        try #require(model.startCall(to: .group(groupID), accountAccessID: model.accountAccessID))
        other.callSession.authenticate(["alice"])

        try scenario.fixture.deliverProfile(from: replacement, to: other)
        #expect(model.callAccessAdmittedMemberships.isEmpty)
        #expect(model.groupRepository.storedGroup(groupID)?.members.map(\.id) == ["bob"])
    }

    @Test func restoreRejectsAnotherOwnerAndAnExpiredCertificateBeforeWriting() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        _ = try repository.load(localMemberID: "alice")
        let original = store.snapshot
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let other = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        #expect(throws: GroupStorageError.identityConflict) {
            try repository.restoreCallRelationships(
                scenario.confirmedRestore(owner: try #require(other.principal)), as: signer, trust: scenario.trust)
        }
        let expiry = try #require(signer.identity?.expiresAt)
        #expect(throws: GroupStorageError.identityConflict) {
            try repository.restoreCallRelationships(
                scenario.confirmedRestore(), as: signer, trust: scenario.trust, now: expiry)
        }
        #expect(store.snapshot == original)
        #expect(credentials.values.isEmpty)
    }

    @Test func restoreDoesNotPublishPartOfTheBatchAndCanRetryAfterReload() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        _ = try repository.load(localMemberID: "alice")
        let original = store.snapshot
        let batch = try scenario.confirmedRestore()

        store.failSaving = true
        #expect(throws: IntercomGroupError.storageUnavailable) {
            try repository.restoreCallRelationships(batch, as: signer, trust: scenario.trust)
        }
        #expect(store.snapshot == original)
        #expect(repository.writableSnapshot == nil)
        store.failSaving = false
        _ = try repository.load(localMemberID: "alice")
        #expect(credentials.values.isEmpty)
        try repository.restoreCallRelationships(batch, as: signer, trust: scenario.trust)
        let imported = store.snapshot
        #expect(Set(imported.groups.map(\.id)) == [scenario.groupID, scenario.directID])
        #expect(Set(credentials.values.keys) == Set(imported.credentialReferences))
        #expect(throws: GroupStorageError.invalidUpdate) {
            try repository.restoreCallRelationships(batch, as: signer, trust: scenario.trust)
        }
        #expect(store.snapshot == imported)
        #expect(Set(credentials.values.keys) == Set(imported.credentialReferences))
    }

    @Test(arguments: [false, true])
    func restoreChecksTheOldInvitationKeyWhenTheGroupHasNoAccountBinding(reusesKey: Bool) throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        _ = try repository.load(localMemberID: "alice")
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let peer = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        let original = store.snapshot
        let previous = scenario.oldSigner.memberID
        let records = scenario.backup.groups.map { saved in
            guard saved.id == scenario.groupID else { return saved }
            var group = saved
            group.accountDevices.removeValue(forKey: previous)
            group.invitationDeviceKeys = [
                previous: reusesKey ? signer.publicKey : scenario.backupOwner.publicKey,
                peer.memberID: peer.publicKey
            ]
            return group
        }
        let confirmed = try scenario.confirmedRestore(records: records)

        if reusesKey {
            #expect(throws: GroupStorageError.identityConflict) {
                try repository.restoreCallRelationships(confirmed, as: signer, trust: scenario.trust)
            }
            let snapshotStayedUnchanged = store.snapshot == original
            let credentialsStayedEmpty = credentials.values.isEmpty
            #expect(snapshotStayedUnchanged)
            #expect(credentialsStayedEmpty)
            return
        }

        try repository.restoreCallRelationships(confirmed, as: signer, trust: scenario.trust)
        _ = try repository.load(localMemberID: signer.memberID)

        let group = try #require(repository.writableSnapshot?.groups.first { $0.id == scenario.groupID })
        #expect(group.invitationDeviceKeys == [peer.memberID: peer.publicKey])
        #expect(group.accountDevices[signer.memberID]?.publicKey == signer.publicKey)
    }

    @Test func restoreRejectsAGroupThatStillExcludesTheOwnerBeforeWritingAnyKeys() throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let store = InMemoryGroupStore(), credentials = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: credentials)
        _ = try repository.load(localMemberID: "alice")
        let original = store.snapshot
        let signer = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let records = scenario.backup.groups.map { saved in
            guard saved.id == scenario.groupID else { return saved }
            var group = saved
            group.removedMembers = [.init(memberIDs: [scenario.oldSigner.memberID],
                                          principal: scenario.backupOwner.principal, removedAt: 1)]
            return group
        }
        let excluded = try scenario.confirmedRestore(records: records)

        #expect(throws: GroupStorageError.invalidUpdate) {
            try repository.restoreCallRelationships(excluded, as: signer, trust: scenario.trust)
        }
        #expect(store.snapshot == original)
        #expect(credentials.values.isEmpty)
    }
}
