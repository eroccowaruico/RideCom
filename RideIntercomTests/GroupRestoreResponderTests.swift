import Foundation
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
        try markResponderAsAnInvitedMember(in: repository, groupID: scenario.groupID)
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

    private func groupRequest(
        _ scenario: ReplacementScenario, addressedTo responder: DeviceIdentitySigner,
        now: Date, registration: UUID? = nil
    ) throws -> CallRelationshipRestoreRequest {
        let requester = try scenario.replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let peer = AccountDeviceBinding(principal: try #require(responder.principal), publicKey: responder.publicKey)
        return try CallRelationshipRestoreRequest(callID: scenario.groupID, recipientMemberID: responder.memberID,
            recipient: peer, signer: requester, now: now, confirmedRegistrationID: registration)
    }

    private func markResponderAsAnInvitedMember(in repository: GroupRepository, groupID: UUID) throws {
        let saved = try #require(repository.writableSnapshot)
        let index = try #require(saved.groups.firstIndex { $0.id == groupID })
        try repository.amend(saved) { next in next.groups[index].joinedByInvitation = true }
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
