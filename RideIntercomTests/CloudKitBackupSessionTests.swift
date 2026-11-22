import CloudKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CloudKitBackupSessionTests {
    @Test func lateAccountLookupCannotReplaceTheAccountFromTheChangeNotification() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        _ = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: "first")
        cloud.pauseNextLookup = true
        defer { cloud.finishPausedLookup() }
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        let earlier = try #require(session.task)
        await AppTestSupport.waitUntil { cloud.pausedLookup != nil }
        try #require(cloud.pausedLookup != nil)

        cloud.account = "second"
        cloud.center.post(name: .CKAccountChanged, object: nil)
        await session.task?.value
        let active = try #require(model.callRelationshipBackupSync)
        await active.task?.value
        cloud.finishPausedLookup()
        await earlier.value

        #expect(app.viewModel?.callRelationshipBackupSync === active)
        #expect(cloud.writtenAccounts == ["second"])
        #expect(cloud.records["first"] == nil)
    }

    @Test func accountChangingDuringReadIsCheckedAgainBeforeWriting() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        let id = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: "first")
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        await session.task?.value
        let original = try #require(model.callRelationshipBackupSync)
        await original.task?.value
        #expect(cloud.writtenAccounts == ["first"])

        cloud.accountAfterRead = "second"
        #expect(model.renameGroup(id, to: "Latest name"))
        await original.task?.value
        #expect(model.callRelationshipBackupSync == nil)
        #expect(cloud.writtenAccounts == ["first"])
        #expect(cloud.records["second"] == nil)

        app.systemSurfaceIsForeground = true
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.callRelationshipBackupSync?.status == .saved)
        #expect(cloud.writtenAccounts == ["first", "second"])
    }

    @Test func foregroundRetriesAnUnavailableICloudAccountWithoutChangingLocalData() async throws {
        let accounts = AccountCallFixture(); defer { accounts.disconnect() }
        let model = try accounts.peer("rider", account: "a").viewModel
        let id = try addGroup(to: model)
        let cloud = CloudAccountFixture(account: nil)
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        await session.task?.value
        #expect(model.callRelationshipBackupSync == nil)
        #expect(cloud.writtenAccounts.isEmpty)
        #expect(model.groups.map(\.id) == [id])

        cloud.account = "available"
        app.systemSurfaceIsForeground = true
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        #expect(cloud.writtenAccounts == ["available"])
        #expect(model.groups.map(\.id) == [id])
    }

    enum RestoreChange: CaseIterable, Sendable { case contactRemoved, groupRemoved, otherGroupRenamed, accountChanged }

    @Test(arguments: RestoreChange.allCases)
    func restorationChecksTheCurrentCloudCandidatesAndAccount(change: RestoreChange) async throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let plan = try scenario.confirmedRestore()
        let kind: IntercomGroup.Kind = change == .groupRemoved ? .group : .direct
        let batch = ConfirmedCallRestore(owner: plan.owner, previousMemberID: plan.previousMemberID,
                                         users: kind == .group ? [] : plan.users,
                                         calls: plan.calls.filter { $0.context.record.kind == kind })
        let sourceStore = InMemoryGroupStore()
        sourceStore.snapshot = scenario.backup
        let groupIndex = try #require(sourceStore.snapshot.groups.firstIndex { $0.id == scenario.groupID })
        sourceStore.snapshot.groups[groupIndex].accountDevices[scenario.oldSigner.memberID] = scenario.backupOwner
        let source = GroupRepository(store: sourceStore, credentials: scenario.restoredCredentials)
        var groups = try source.load(localMemberID: scenario.oldSigner.memberID)
        let now = Date().timeIntervalSince1970
        let earlier = try source.callRelationshipBackup(as: scenario.oldSigner, now: now)
        #expect(earlier.contacts.map(\.id) == [scenario.savedPersonID])
        #expect(earlier.groups.map(\.id) == [scenario.groupID])

        let cloud = CloudAccountFixture(account: "first")
        let stored = try await cloud.store.save(earlier, replacing: nil, as: scenario.oldSigner, now: now)
        switch change {
        case .contactRemoved: try source.removeUser(scenario.savedPersonID)
        case .groupRemoved: try source.delete(scenario.groupID, remaining: groups.filter { $0.id != scenario.groupID })
        case .otherGroupRenamed:
            let editable = try #require(groups.firstIndex { $0.id == scenario.groupID })
            groups[editable].name = "Renamed group"
            try source.save(groups)
        case .accountChanged: break
        }
        let latest = try source.callRelationshipBackup(as: scenario.oldSigner, now: now)
        _ = try await cloud.store.save(latest, replacing: stored, as: scenario.oldSigner, now: now)

        let model = scenario.replacement.viewModel
        let session = cloud.session()
        let app = AppCallOwner(account: model.accountSession, viewModel: model,
                               widgetDestinationStore: .init(fileURL: nil), backupSession: session)
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        let initial = scenario.replacement.groupStore.snapshot
        if change == .otherGroupRenamed {
            try await session.restore(batch, from: earlier)
            #expect(app.viewModel?.groups.map(\.id) == [scenario.directID])
            #expect(app.viewModel?.savedRemoteUsers.map(\.id) == [scenario.savedPersonID])
        } else {
            if change == .accountChanged { cloud.accountAfterRead = "second" }
            let error: CloudKitCallRelationshipBackupSession.Failure =
                change == .accountChanged ? .accountUnavailable : .backupChanged
            await #expect(throws: error) { try await session.restore(batch, from: earlier) }
            #expect(scenario.replacement.groupStore.snapshot == initial)
            let keys = try #require(scenario.fixture.credentialStores["alice"])
            #expect(keys.values.isEmpty)
        }
    }

    private func addGroup(to model: IntercomViewModel) throws -> UUID {
        let id = UUID()
        let member = model.localMemberIdentity.memberID
        let signer = try model.internetSettingsStore.invitationSigner(memberID: member)
        let binding = AccountDeviceBinding(principal: try #require(signer.principal), publicKey: signer.publicKey)
        let group = try IntercomGroup(id: id, name: "Riders", members: [.init(id: member, displayName: "Rider")],
                                      accountDevices: [member: binding])
        try #require(model.commitGroups([group]))
        return id
    }

    @Test func restoreDoesNotSaveAConfirmationFromAnotherDeviceOfTheSameContact() async throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let fixtures = scenario.fixture
        let staleDevice = try fixtures.peer("bob-other", account: "b")
        let oldDevice = try fixtures.peer("alice-old", account: "a")
        staleDevice.viewModel.allowsNearbyGroupDelivery = false
        oldDevice.viewModel.allowsNearbyGroupDelivery = false
        _ = try fixtures.completeGroupContactRegistration(from: staleDevice, to: oldDevice)
        let stale = staleDevice.viewModel
        let contact = try #require(stale.savedRemoteUsers.first)
        try #require(stale.selectUser(contact.id, connectIfIdle: false))
        let record = try #require(staleDevice.groupStore.snapshot.groups.first { $0.id == scenario.directID })
        let credential = try #require(try stale.groupRepository.credential(for: record.id))

        let replacement = scenario.replacement.viewModel
        let requester = try replacement.internetSettingsStore.invitationSigner(memberID: "alice")
        let responder = try stale.internetSettingsStore.invitationSigner(memberID: "bob-other")
        let principal = try #require(responder.principal)
        let recipient = AccountDeviceBinding(principal: principal, publicKey: responder.publicKey)
        let now = Date()
        let request = try CallRelationshipRestoreRequest(callID: record.id, recipientMemberID: responder.memberID,
                                                          recipient: recipient, signer: requester, now: now)
        let response = try #require(try stale.groupRepository.confirmRestore(
            request, as: responder, trust: scenario.trust, now: now))
        let context = CallRelationshipRestoreContext(
            request: request, confirmation: response, record: record)
        let transfer = try CallRelationshipRestoreCredential(
            credential, for: context, as: responder, trust: scenario.trust, now: now)
        var saved = try #require(scenario.backup.users.first { $0.id == scenario.savedPersonID })
        saved.memberIDs = [responder.memberID]
        saved.deviceKeys = [responder.memberID: responder.publicKey]
        let batch = ConfirmedCallRestore(owner: scenario.backupOwner.principal,
            previousMemberID: oldDevice.viewModel.localMemberIdentity.memberID, users: [saved],
            calls: [.init(context: context, transferredCredential: transfer)])

        let sourceStore = InMemoryGroupStore()
        sourceStore.snapshot = scenario.backup
        let repository = GroupRepository(store: sourceStore, credentials: scenario.restoredCredentials)
        _ = try repository.load(localMemberID: scenario.oldSigner.memberID)
        let candidate = try repository.callRelationshipBackup(as: scenario.oldSigner, now: now.timeIntervalSince1970)
        _ = try #require(candidate.contacts.first?.restoreRecipientFingerprint)
        let cloud = CloudAccountFixture(account: "first")
        _ = try await cloud.store.save(
            candidate, replacing: nil, as: scenario.oldSigner, now: now.timeIntervalSince1970)
        let session = cloud.session()
        session.bind(to: replacement)
        await session.task?.value
        await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.backupChanged) {
            try await session.restore(batch, from: candidate)
        }
        #expect(scenario.replacement.groupStore.snapshot.groups.isEmpty)
    }
}

extension CloudKitBackupSessionTests {
    enum ResponderState: CaseIterable, Sendable { case unchanged, contactRemoved, accountChanged }

    @Test(arguments: ResponderState.allCases)
    func directRestoreChecksTheRespondersLatestCloudContact(state: ResponderState) async throws {
        let scenario = try ReplacementScenario(); defer { scenario.fixture.disconnect() }
        let model = scenario.other.viewModel
        let signer = try #require(try model.callRelationshipBackupSigner())
        let requester = try #require(try scenario.replacement.viewModel.callRelationshipBackupSigner())
        let principal = try #require(signer.principal)
        let direct = try CallRelationshipRestoreRequest(callID: scenario.directID, recipientMemberID: signer.memberID,
            recipient: .init(principal: principal, publicKey: signer.publicKey), signer: requester, now: Date())
        let cloud = CloudAccountFixture(account: "first")
        let session = cloud.session()
        session.bind(to: model)
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        let time = Date().timeIntervalSince1970
        let stored = try #require(try await cloud.store.load(as: signer, now: time))
        let before = scenario.other.groupStore.snapshot
        let contact = try #require(stored.backup.contacts.first)
        if state == .contactRemoved {
            let peerStore = InMemoryGroupStore(), peerKeys = InMemoryGroupCredentialStore()
            peerStore.snapshot = before
            peerKeys.values = try #require(scenario.fixture.credentialStores["bob"]).values
            let peer = GroupRepository(store: peerStore, credentials: peerKeys)
            _ = try peer.load(localMemberID: signer.memberID)
            try peer.removeUser(contact.id)
            let updated = try peer.callRelationshipBackup(as: signer, now: time)
            _ = try await cloud.store.save(updated, replacing: stored, as: signer, now: time)
        }

        if state == .accountChanged {
            cloud.accountAfterRead = "second"
            await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.accountUnavailable) {
                try await session.confirmDirectRestore(direct)
            }
        } else {
            let response = try await session.confirmDirectRestore(direct)
            if state == .unchanged {
                let confirmation = try #require(response)
                #expect(try confirmation.verify(for: direct, as: requester, trust: scenario.trust,
                                                now: Date()).callID == scenario.directID)
            } else {
                #expect(response == nil)
            }
        }
        #expect(scenario.other.groupStore.snapshot == before)
    }
}

@MainActor
private final class CloudAccountFixture {
    let center = NotificationCenter()
    var account: String?
    var accountAfterRead: String?
    var pauseNextLookup = false
    var pausedLookup: CheckedContinuation<Void, Never>?
    var records: [String: CKRecord] = [:]
    var writtenAccounts: [String] = []

    init(account: String?) { self.account = account }

    var store: CloudKitCallRelationshipBackupStore {
        .init(fetch: { id in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            let record = self.records[active]
            if let next = self.accountAfterRead {
                self.account = next
                self.accountAfterRead = nil
            }
            guard let record, record.recordID == id else { throw CKError(.unknownItem) }
            return record
        }, write: { record, _ in
            guard let active = self.account else { throw CKError(.notAuthenticated) }
            self.records[active] = record
            self.writtenAccounts.append(active)
            return record
        })
    }

    func session() -> CloudKitCallRelationshipBackupSession {
        .init(store: store, keychain: DictionaryKeychain(), namespace: "CloudFixture", center: center) {
            let found = self.account
            if self.pauseNextLookup {
                self.pauseNextLookup = false
                await withCheckedContinuation { self.pausedLookup = $0 }
            }
            return found.map { .init(container: "fixture", environment: .development, account: $0) }
        }
    }

    func finishPausedLookup() {
        pausedLookup?.resume()
        pausedLookup = nil
    }
}
