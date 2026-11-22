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
        sourceStore.snapshot = scenario.old.groupStore.snapshot
        let groupIndex = try #require(sourceStore.snapshot.groups.firstIndex { $0.id == scenario.groupID })
        sourceStore.snapshot.groups[groupIndex].accountDevices[scenario.oldSigner.memberID] = scenario.backupOwner
        let credentials = try #require(scenario.fixture.credentialStores[scenario.oldSigner.memberID])
        let source = GroupRepository(store: sourceStore, credentials: credentials)
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
        let now = Date()
        let candidate = try scenario.old.viewModel.groupRepository.callRelationshipBackup(
            as: scenario.oldSigner, now: now.timeIntervalSince1970)
        let registration = try #require(candidate.contacts.first?.confirmedRegistrationID)
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
        let request = try CallRelationshipRestoreRequest(callID: record.id, recipientMemberID: responder.memberID,
                                                          recipient: recipient, signer: requester, now: now,
                                                          confirmedRegistrationID: registration)
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
    enum ResponderState: CaseIterable, Sendable {
        case unchanged, contactRemoved, accountChanged, relayedDeletion, relayUnavailable, missingRegistration
        case rotatedKey, missingKey
    }

    @Test(arguments: ResponderState.allCases)
    func directRestoreChecksTheRespondersLatestCloudContact(state: ResponderState) async throws {
        let scenario = try ReplacementScenario(fixture: .init(origin: "https://delivery.test"))
        defer { scenario.fixture.disconnect() }
        let model = scenario.other.viewModel
        let person = try #require(model.savedRemoteUsers.first?.id)
        try #require(model.renameSavedUser(person, displayName: "Responder private alias"))
        defer { model.stopGroupDeliverySync(); GroupDeliveryHTTPStub.reset() }
        try prepareContactDeletionRelay(in: model)
        let signer = try #require(try model.callRelationshipBackupSigner())
        let requester = try #require(try scenario.replacement.viewModel.callRelationshipBackupSigner())
        let direct = try directRequest(scenario, to: signer, from: requester,
                                       omitRegistration: state == .missingRegistration)
        let cloud = CloudAccountFixture(account: "first")
        let session = cloud.session()
        session.bind(to: model)
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value
        let before = scenario.other.groupStore.snapshot
        if state == .contactRemoved {
            try await removeContactFromCloud(cloud, scenario: scenario, as: signer)
        }
        var relayReadCount = 0
        if state == .relayedDeletion {
            try installRestoreDeletion(scenario) { relayReadCount += 1 }
        } else if state == .relayUnavailable {
            GroupDeliveryHTTPStub.onContactDeletion = { _, _ in (503, [:]) }
        }
        try changeKeyDuringRead(state, cloud: cloud, scenario: scenario)

        if state == .accountChanged {
            cloud.accountAfterRead = "second"
            await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.accountUnavailable) {
                try await session.respondToDirectRestore(direct)
            }
        } else {
            let response = try await session.respondToDirectRestore(direct)
            if state == .unchanged || state == .rotatedKey {
                try await verifyDirectResponse(try #require(response), request: direct, scenario: scenario)
            } else {
                #expect(response == nil)
            }
        }
        if state == .relayedDeletion {
            #expect(relayReadCount == 1)
            #expect(model.savedRemoteUsers.isEmpty)
            #expect(try model.groupRepository.credential(for: scenario.directID) == nil)
            #expect(model.groups.contains { $0.id == scenario.groupID })
        } else if state != .rotatedKey {
            #expect(scenario.other.groupStore.snapshot == before)
        }
    }

    private func verifyDirectResponse(_ response: DirectCallRestoreResponse, request: CallRelationshipRestoreRequest,
                                      scenario: ReplacementScenario) async throws {
        let data = try JSONEncoder().encode(response)
        let delivered = try JSONDecoder().decode(DirectCallRestoreResponse.self, from: data)
        let now = Date().timeIntervalSince1970
        let backup = try scenario.old.viewModel.groupRepository.callRelationshipBackup(as: scenario.oldSigner, now: now)
        let cloud = CloudAccountFixture(account: "requester")
        _ = try await cloud.store.save(backup, replacing: nil, as: scenario.oldSigner, now: now)
        let model = scenario.replacement.viewModel
        let destination = cloud.session()
        destination.bind(to: model)
        await destination.task?.value
        await model.callRelationshipBackupSync?.task?.value
        #expect(model.groups.isEmpty)

        try await destination.restoreDirect(delivered, to: request, for: scenario.savedPersonID, from: backup)

        let current = try #require(try scenario.other.viewModel.groupRepository.credential(for: scenario.directID))
        let restored = try model.groupRepository.credential(for: scenario.directID)
        let usesCurrentKey = restored == current
        #expect(usesCurrentKey)
        #expect(model.savedRemoteUsers.map(\.id) == [scenario.savedPersonID])
        #expect(model.savedRemoteUsers.first?.localName == nil)
        #expect(model.groups.map(\.id) == [scenario.directID])
        let members = try #require(model.groups.first?.members.map(\.id))
        let responderID = scenario.other.viewModel.localMemberIdentity.memberID
        #expect(Set(members) == [model.localMemberIdentity.memberID, responderID])
    }

    private func changeKeyDuringRead(_ state: ResponderState, cloud: CloudAccountFixture,
                                     scenario: ReplacementScenario) throws {
        let model = scenario.other.viewModel
        switch state {
        case .rotatedKey:
            cloud.afterRead = {
                let key = GroupAccessCredential(groupID: scenario.directID, secret: "rotated-fixture-key")
                try model.groupRepository.update(model.groups, credential: key)
            }
        case .missingKey:
            let store = try #require(scenario.fixture.credentialStores["bob"])
            let direct = try #require(scenario.other.groupStore.snapshot.groups.first { $0.id == scenario.directID })
            let reference = try #require(direct.credentialReference)
            cloud.afterRead = { store.values[reference] = nil }
        default:
            break
        }
    }

    private func directRequest(
        _ scenario: ReplacementScenario, to signer: DeviceIdentitySigner, from requester: DeviceIdentitySigner,
        omitRegistration: Bool
    ) throws -> CallRelationshipRestoreRequest {
        let now = Date()
        if omitRegistration {
            let principal = try #require(signer.principal)
            return try .init(callID: scenario.directID, recipientMemberID: signer.memberID,
                             recipient: .init(principal: principal, publicKey: signer.publicKey),
                             signer: requester, now: now)
        }
        let candidate = try scenario.old.viewModel.groupRepository.callRelationshipBackup(
            as: scenario.oldSigner, now: now.timeIntervalSince1970)
        let identity = try #require(signer.identity)
        return try #require(try candidate.directRestoreRequest(
            for: scenario.savedPersonID, to: identity, as: requester, now: now))
    }

    private func prepareContactDeletionRelay(in model: IntercomViewModel) throws {
        GroupDeliveryHTTPStub.reset()
        model.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        let access = try #require(try model.internetSettingsStore.notificationAccess(
            memberID: model.localMemberIdentity.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: access.principal.userID]
    }

    private func removeContactFromCloud(
        _ cloud: CloudAccountFixture, scenario: ReplacementScenario, as signer: DeviceIdentitySigner
    ) async throws {
        let time = Date().timeIntervalSince1970
        let stored = try #require(try await cloud.store.load(as: signer, now: time))
        let contact = try #require(stored.backup.contacts.first)
        let peerStore = InMemoryGroupStore(), peerKeys = InMemoryGroupCredentialStore()
        peerStore.snapshot = scenario.other.groupStore.snapshot
        peerKeys.values = try #require(scenario.fixture.credentialStores["bob"]).values
        let peer = GroupRepository(store: peerStore, credentials: peerKeys)
        _ = try peer.load(localMemberID: signer.memberID)
        try peer.removeUser(contact.id)
        let updated = try peer.callRelationshipBackup(as: signer, now: time)
        _ = try await cloud.store.save(updated, replacing: stored, as: signer, now: time)
    }

    private func installRestoreDeletion(_ scenario: ReplacementScenario, onRead: @escaping () -> Void) throws {
        let writer = try #require(scenario.fixture.peers.first {
            $0.viewModel.localMemberIdentity.memberID == "alice-old"
        }).viewModel
        let settings = writer.internetSettingsStore
        let deletionSigner = try #require(try settings.contactDeletionSigner(memberID: "alice-old"))
        try writer.groupRepository.removeUser(scenario.savedPersonID, signer: deletionSigner,
                                             sender: scenario.oldSigner.principal)
        let publication = try #require(writer.groupRepository.contactDeletionPublications.first)
        let payload = try #require(publication.payload)
        GroupDeliveryHTTPStub.onContactDeletion = { request, _ in
            if request.url?.path == "/api/contact-deletions/receipt" { return (200, ["state": "received"]) }
            guard request.url?.path == "/api/contact-deletions/read" else { return (404, [:]) }
            onRead()
            return (200, ["deletion": [
                "id": publication.id.uuidString, "expiresAt": publication.expiresAt, "packet": payload.packet
            ]])
        }
    }
}
