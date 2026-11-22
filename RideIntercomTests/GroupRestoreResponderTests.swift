import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupRestoreResponderTests {
    enum MembershipChange: CaseIterable, Sendable {
        case current, excludedDuringRead, responderLeft, noBackup
    }

    @Test(arguments: MembershipChange.allCases)
    func aGroupRestoreSealsOnlyTheCurrentKeyForAStillEligibleMember(change: MembershipChange) async throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let model = scenario.other.viewModel
        let repository = model.groupRepository
        let responder = try model.internetSettingsStore.invitationSigner(memberID: "bob")
        try setInvitationRole(true, in: model, groupID: scenario.groupID)
        let now = Date()
        let request = try groupRequest(scenario, addressedTo: responder, now: now)
        let cloud = CloudAccountFixture(account: "group-restore-responder")
        let backup = try repository.callRelationshipBackup(as: responder, now: now.timeIntervalSince1970)
        _ = try await cloud.store.save(backup, replacing: nil, as: responder, now: now.timeIntervalSince1970)
        let session = cloud.session()
        session.bind(to: model)
        defer { session.bind(to: nil) }
        await session.task?.value
        await model.callRelationshipBackupSync?.task?.value

        let groupID = scenario.groupID
        switch change {
        case .current:
            try repository.update(model.groups, credential: .init(groupID: groupID, secret: "rotated-key-fixture"))
        case .excludedDuringRead:
            cloud.afterRead = { try #require(model.removeMember("alice-old", from: groupID)) }
        case .responderLeft:
            try #require(model.deleteGroup(groupID))
        case .noBackup:
            cloud.records.removeAll()
        }
        let response = try await session.respondToGroupRestore(request)
        if change == .current {
            try assertCurrentGroupResponse(try #require(response), for: request, in: scenario, now: now)
        } else {
            #expect(response == nil)
        }
    }

    @Test func aGroupRestoreRequestCannotUseADirectRegistration() throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let now = Date()
        let responder = try scenario.other.viewModel.internetSettingsStore.invitationSigner(memberID: "bob")
        let request = try groupRequest(scenario, addressedTo: responder, now: now, registration: UUID())
        let confirmation = try scenario.other.viewModel.groupRepository.confirmRestore(
            request, as: responder, trust: scenario.trust, now: now)
        #expect(confirmation == nil)
    }

    @Test(arguments: [false, true])
    func restoresGroupFromEncodedResponseAndKeepsTheRequestersRole(joined: Bool) async throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let old = scenario.old.viewModel
        let replacement = scenario.replacement.viewModel
        let groupID = scenario.groupID
        try #require(old.renameGroup(groupID, to: "My saved name"))
        try setInvitationRole(joined, in: old, groupID: groupID)
        try setInvitationRole(!joined, in: scenario.other.viewModel, groupID: groupID)
        let source = CloudAccountFixture(account: "group-restore-source")
        let original = try await saveGroupBackup(of: old, to: source)
        try #require(original.backup.groups.contains { $0.id == groupID && $0.joinedByInvitation == joined })
        let (request, response) = try await makeGroupResponse(scenario)

        try #require(replacement.createTalkGroup(name: "Another call"))
        let existingID = try #require(replacement.selectedGroup?.id)
        let existingKey = try #require(try replacement.groupRepository.credential(for: existingID))
        try #require(replacement.startCall(to: .group(existingID), accountAccessID: replacement.accountAccessID))
        let activeCall = replacement.currentCallReference
        try await restoreGroup(response, to: request, groupID: groupID,
                               from: (source, original.backup), on: replacement)
        #expect(replacement.currentCallReference == activeCall)
        #expect(try replacement.groupRepository.credential(for: existingID) == existingKey)
        #expect(replacement.groupRepository.ownsGroup(groupID) == !joined)
        #expect(replacement.groups.first { $0.id == groupID }?.name == "My saved name")
        #expect(replacement.savedRemoteUsers.isEmpty)
        let expected = try #require(try scenario.other.viewModel.groupRepository.credential(for: groupID))
        #expect(try replacement.groupRepository.credential(for: groupID) == expected)
        try assertRestoredGroupAdmission(in: scenario)

        try #require(replacement.deleteGroup(groupID))
        let reopened = try scenario.fixture.restart(scenario.replacement).viewModel
        await #expect(throws: GroupStorageError.invalidUpdate) {
            try await restoreGroup(response, to: request, groupID: groupID,
                                   from: (source, original.backup), on: reopened)
        }
        #expect(try reopened.groupRepository.credential(for: groupID) == nil)
        #expect(try reopened.groupRepository.credential(for: existingID) == existingKey)
    }

    @Test func refusesToRestoreWhenTheRequestersSavedRoleChanged() async throws {
        let scenario = try ReplacementScenario()
        defer { scenario.fixture.disconnect() }
        let old = scenario.old.viewModel
        let groupID = scenario.groupID
        try setInvitationRole(true, in: old, groupID: groupID)
        let cloud = CloudAccountFixture(account: "group-role-changed")
        let saved = try await saveGroupBackup(of: old, to: cloud)
        let candidate = try #require(saved.backup.groups.first { $0.id == groupID })
        let (request, response) = try await makeGroupResponse(scenario)
        try setInvitationRole(candidate.joinedByInvitation != true, in: old, groupID: groupID)
        let signer = try #require(try old.callRelationshipBackupSigner())
        let now = Date().timeIntervalSince1970
        let changed = try old.groupRepository.callRelationshipBackup(as: signer, now: now)
        _ = try await cloud.store.save(changed, replacing: saved, as: signer, now: now)
        let replacement = scenario.replacement.viewModel
        await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.backupChanged) {
            try await restoreGroup(response, to: request, groupID: groupID,
                                   from: (cloud, saved.backup), on: replacement)
        }
        #expect(try replacement.groupRepository.credential(for: groupID) == nil)
        #expect(replacement.groups.isEmpty)
    }

    private func assertRestoredGroupAdmission(in scenario: ReplacementScenario) throws {
        let requester = scenario.replacement, holder = scenario.other
        for endpoint in [requester, holder] {
            let model = endpoint.viewModel
            try #require(model.startCall(to: .group(scenario.groupID), accountAccessID: model.accountAccessID))
        }
        requester.callSession.authenticate(["bob"])
        holder.callSession.authenticate(["alice"])
        try scenario.fixture.deliverProfile(from: requester, to: holder)
        try scenario.fixture.deliverProfile(from: holder, to: requester)
        #expect(requester.viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["bob"])
        #expect(holder.viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue) == ["alice"])
    }

    private func makeGroupResponse(_ scenario: ReplacementScenario) async throws
        -> (CallRelationshipRestoreRequest, CallRelationshipRestoreResponse) {
        let responder = scenario.other.viewModel
        let signer = try #require(try responder.callRelationshipBackupSigner())
        let request = try groupRequest(scenario, addressedTo: signer, now: Date())
        let cloud = CloudAccountFixture(account: "group-restore-target")
        _ = try await saveGroupBackup(of: responder, to: cloud)
        let session = cloud.session()
        session.bind(to: responder)
        defer { session.bind(to: nil) }
        await session.task?.value
        let response = try #require(try await session.respondToGroupRestore(request))
        return (request, try JSONDecoder().decode(
            CallRelationshipRestoreResponse.self, from: JSONEncoder().encode(response)))
    }

    private func saveGroupBackup(of model: IntercomViewModel, to cloud: CloudAccountFixture) async throws
        -> CloudKitCallRelationshipBackupStore.Saved {
        let signer = try #require(try model.callRelationshipBackupSigner())
        let now = Date().timeIntervalSince1970
        let backup = try model.groupRepository.callRelationshipBackup(as: signer, now: now)
        return try await cloud.store.save(backup, replacing: nil, as: signer, now: now)
    }

    private func restoreGroup(
        _ response: CallRelationshipRestoreResponse, to request: CallRelationshipRestoreRequest, groupID: UUID,
        from source: (cloud: CloudAccountFixture, backup: CallRelationshipBackup), on model: IntercomViewModel
    ) async throws {
        let session = source.cloud.session()
        session.bind(to: model)
        defer { session.bind(to: nil) }
        await session.task?.value
        try await session.restoreGroup(response, to: request, for: groupID, from: source.backup)
    }

    private func groupRequest(
        _ scenario: ReplacementScenario, addressedTo responder: DeviceIdentitySigner,
        now: Date, registration: UUID? = nil
    ) throws -> CallRelationshipRestoreRequest {
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let peer = AccountDeviceBinding(principal: try #require(responder.principal), publicKey: responder.publicKey)
        return try CallRelationshipRestoreRequest(callID: scenario.groupID, recipientMemberID: responder.memberID,
            recipient: peer, signer: requester, now: now, confirmedRegistrationID: registration)
    }

    private func setInvitationRole(_ joined: Bool, in model: IntercomViewModel, groupID: UUID) throws {
        let signer = try #require(try model.callRelationshipBackupSigner())
        let owner = try #require(signer.principal)
        let repository = model.groupRepository
        let saved = try #require(repository.writableSnapshot)
        let index = try #require(saved.groups.firstIndex { $0.id == groupID })
        try repository.amend(saved) { next in
            next.groups[index].accountDevices[signer.memberID] = .init(principal: owner, publicKey: signer.publicKey)
            next.groups[index].joinedByInvitation = joined
        }
    }

    private func assertCurrentGroupResponse(
        _ response: CallRelationshipRestoreResponse, for request: CallRelationshipRestoreRequest,
        in scenario: ReplacementScenario, now: Date
    ) throws {
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let old = try scenario.old.viewModel.internetSettingsStore.invitationSigner(memberID: "alice-old")
        let repository = scenario.other.viewModel.groupRepository
        var membership = try #require(repository.writableSnapshot?.groups.first { $0.id == scenario.groupID })
        #expect(membership.joinedByInvitation == true)
        let responderMembership = CallRelationshipRestoreContext(
            request: request, confirmation: response.confirmation, record: membership)
        #expect(throws: DeviceIdentityProof.Failure.self) {
            try response.credential.open(for: responderMembership, as: requester, trust: scenario.trust, now: now)
        }
        membership.joinedByInvitation = nil
        let context = CallRelationshipRestoreContext(request: request, confirmation: response.confirmation,
                                                     record: membership)
        let received = try response.credential.open(for: context, as: requester, trust: scenario.trust, now: Date())
        #expect(received.confirmation.previousMemberID == "alice-old")
        #expect(received.credential == (try repository.credential(for: scenario.groupID)))
        #expect(throws: DeviceIdentityProof.Failure.self) {
            try response.credential.open(for: context, as: old, trust: scenario.trust, now: Date())
        }
    }
}
