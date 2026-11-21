import Foundation
import Observation
import SessionManager
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct CallAccessTests {
    @Test func resumeWindowIncludesBoundaryAndRejectsMissingInvalidOrFutureTime() {
        #expect(CallAccessState.permitsResume(since: 100, now: 86_500))
        #expect(!CallAccessState.permitsResume(since: 100, now: 86_500.001))
        for value: TimeInterval? in [nil, 0, -1, .infinity, .nan, 101] {
            #expect(!CallAccessState.permitsResume(since: value, now: 100))
        }
    }

    @Test func onlySuccessfulNewSponsoredConversationCreatesWindow() {
        var state = CallAccessState()
        #expect(state.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: false) == nil)
        #expect(!state.isEstablished)
        #expect(state.establish(now: 100, sponsored: true, remoteEstablished: false, mediaReady: true) == 100)
        #expect(state.establish(now: 200, sponsored: true, remoteEstablished: false, mediaReady: true) == nil)
        state.endConversation()
        #expect(state.establish(now: 300, sponsored: true, remoteEstablished: true, mediaReady: true) == nil)
        #expect(state.lastSponsoredStart == 100)
        state.endConversation()
        #expect(state.establish(now: 400, sponsored: false, remoteEstablished: false, mediaReady: true) == nil)
        #expect(state.lastSponsoredStart == 100)
        state.mergeStart(90, now: 500); state.mergeStart(501, now: 500)
        #expect(state.lastSponsoredStart == 100)
        state.mergeStart(450, now: 500)
        #expect(state.lastSponsoredStart == 450)
    }

    @Test func groupTimestampSurvivesEditsAndReloadAndFailureDoesNotInventTime() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        var group = try fixture.group(); try fixture.repository.save([group])
        try fixture.repository.recordSponsoredStart(100, for: group.id, now: 200)
        try fixture.repository.recordSponsoredStart(90, for: group.id, now: 200)
        #expect(throws: (any Error).self) { try fixture.repository.recordSponsoredStart(201, for: group.id, now: 200) }
        group.name = "Renamed"; try fixture.repository.save([group])
        let restarted = fixture.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.lastSponsoredStart(for: group.id) == 100)
        fixture.store.failCommit = true
        #expect(throws: (any Error).self) { try restarted.recordSponsoredStart(150, for: group.id, now: 200) }
        #expect(restarted.lastSponsoredStart(for: group.id) == 100)
        fixture.store.failCommit = false
        _ = try restarted.load(localMemberID: "local")
        try restarted.delete(group.id, remaining: [])
        #expect(restarted.lastSponsoredStart(for: group.id) == nil)
    }

    @Test func confirmationUsesCurrentGroupManagementAccess() throws {
        let source = CallAccessSourceFixture()
        let expiresAt = source.now.addingTimeInterval(1)
        source.value = .init(status: .active, activeUntil: expiresAt)
        let harness = AppTestSupport.makeHarness(enforceCallAccess: true,
            callAccessEvaluation: { _ in source.value }, callAccessNow: { source.now })
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        let rider = try #require(group.members.dropFirst().first)
        let saves = harness.groupStore.saveCount
        #expect(viewModel.canManageRegularGroups, "A valid pass can open the confirmation")

        source.now = expiresAt
        #expect(!viewModel.canManageRegularGroups)
        #expect(!viewModel.removeMember(rider.id, from: group.id))
        #expect(
            viewModel.groupErrorMessage
                == "An active pass is required to remove a member. Check Access in Settings.")
        #expect(viewModel.groups.first?.members == group.members)
        #expect(harness.groupStore.saveCount == saves)
        #expect(viewModel.groupDeliveryTask == nil)

        source.value = .init(status: .active, activeUntil: .distantFuture)
        #expect(viewModel.removeMember(rider.id, from: group.id))
        #expect(viewModel.groupErrorMessage == nil)
        #expect(viewModel.groups.first?.members.contains { $0.id == rider.id } == false)
        #expect(harness.groupStore.saveCount == saves + 1)
    }

    @Test(arguments: [false, true])
    func invitationSelectionKeepsItsDraftWhenThePassExpires(creating: Bool) throws {
        let source = CallAccessSourceFixture()
        let expiresAt = source.now.addingTimeInterval(1)
        source.value = .init(status: .active, activeUntil: expiresAt)
        let harness = AppTestSupport.makeHarness(enforceCallAccess: true,
            callAccessEvaluation: { _ in source.value }, callAccessNow: { source.now })
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let groupID = creating ? nil : try #require(viewModel.groups.first).id
        var selection = MemberSelection(viewModel: viewModel, groupID: groupID)
        selection.addNewPerson()
        selection.newPeople[0].name = "Snow rider"
        let saved = harness.groupStore.snapshot
        #expect(selection.canSave)

        source.now = expiresAt
        #expect(!selection.canSave)
        #expect(selection.saveMessage == IntercomViewModel.groupAccessRequiredMessage)
        #expect(selection.save() == nil)
        #expect(harness.groupStore.snapshot == saved)
        #expect(selection.newPeople[0].resolvedName == "Snow rider")

        source.value = .init(status: .active, activeUntil: .distantFuture)
        #expect(selection.canSave)
        #expect(selection.save() == .some(.some(groupID ?? selection.newGroupID)))
        #expect(viewModel.directoryUsers.contains { $0.resolvedDisplayName == "Snow rider" })
    }
}
