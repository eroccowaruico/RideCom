import AppIntents
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallIntentTests {
    @Test func queryOmitsGroupOnlyPeopleAndDirectGroupsAndRejectsOtherAccountScope() async throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let query = CallTargetQuery(); query.owner = owner
        let targets = try await query.suggestedEntities()
        #expect(targets.count == viewModel.regularGroups.count)
        let other = AppTestSupport.makeHarness(localMemberID: "other-account-device")
        defer { other.viewModel.disconnect() }
        let otherOwner = AppCallOwner(account: other.viewModel.accountSession, viewModel: other.viewModel)
        let otherQuery = CallTargetQuery(); otherQuery.owner = otherOwner
        #expect(try await otherQuery.entities(for: targets.map(\.id)).isEmpty)
        let group = viewModel.groups[0]
        let invite = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: invite))
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.selectUser(user.id))
        #expect(owner.callTargets.count == viewModel.regularGroups.count + 1)
        #expect(owner.callTargets.filter { $0.destination == .user(user.id) }.count == 1)
        let selectedGroup = try #require(viewModel.selectedGroup)
        #expect(!owner.callTargets.contains { $0.destination == .group(selectedGroup.id) })
    }

    @Test func externalStartUsesTheAppModelAndCannotReplaceAnotherCall() async throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let targets = owner.callTargets
        let first = StartSavedCallIntent(target: targets[0].entity); first.owner = owner
        _ = try await first.perform()
        #expect(viewModel.activeGroupID == viewModel.groups[0].id && owner.callPresentationID != nil)
        let reference = viewModel.currentCallReference
        _ = try await first.perform()
        #expect(viewModel.currentCallReference == reference)
        let second = StartSavedCallIntent(target: targets[1].entity); second.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await second.perform() }
        #expect(viewModel.currentCallReference == reference && viewModel.selectedGroup?.id == viewModel.activeGroupID)
        #expect(viewModel.groupErrorMessage?.contains("End the current call") == true)
        let end = EndCurrentCallIntent(); end.owner = owner
        _ = try await end.perform()
        #expect(viewModel.activeGroupID == nil)
    }

    @Test func staleDestinationAndOldLoginCannotStartAndNoHistoryIsAnError() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: fixture.session); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: fixture.session, viewModel: viewModel)
        let recent = StartRecentCallIntent(); recent.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await recent.perform() }
        let oldTarget = owner.callTargets[0].entity
        viewModel.deleteGroup(viewModel.groups[0].id)
        let start = StartSavedCallIntent(target: oldTarget); start.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        fixture.session.signOut(); fixture.signIn()
        #expect(owner.callTargets.isEmpty)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        #expect(viewModel.activeGroupID == nil)
    }

    @Test(arguments: [false, true]) func recentIntentUsesStoredDestinationAndLeavesOtherActiveCallAlone(
        fromControl: Bool
    ) async throws {
        let group = IntercomSeedData.recentGroups[0]
        let harness = AppTestSupport.makeHarness(
            appSettingsStore: InMemoryAppSettingsStore(settings: .init(recentCallDestination: .group(group.id))))
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        func resumeRecent() async throws {
            if fromControl {
                let recent = OpenCallControlIntent(action: .recent); recent.actions = owner
                _ = try await recent.perform()
            } else {
                let recent = StartRecentCallIntent(); recent.owner = owner
                _ = try await recent.perform()
            }
        }
        try await resumeRecent()
        #expect(viewModel.activeGroupID == group.id)
        #expect(viewModel.startCall(to: .group(viewModel.groups[1].id), accountAccessID: viewModel.accountAccessID))
        let reference = viewModel.currentCallReference
        let displayed = owner.callPresentationID
        await #expect(throws: CallIntentError.self) { try await resumeRecent() }
        #expect(viewModel.currentCallReference == reference)
        #expect(owner.callPresentationID == displayed)
        #expect(viewModel.groupErrorMessage?.contains("End the current call") == true)
    }

    @Test func queryUsesCurrentNamesAndEndDoesNotRequireTheDeletedContact() async throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        let invite = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: invite))
        let user = try #require(viewModel.savedRemoteUsers.first)
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let target = try #require(owner.callTargets.first { $0.destination == .user(user.id) }?.entity)
        let query = CallTargetQuery(); query.owner = owner
        #expect(viewModel.renameSavedUser(user.id, displayName: "Ride Friend"))
        #expect(try await query.entities(for: [target.id]).first?.name == "Ride Friend")
        #expect(try await query.entities(matching: "ride friend").map(\.id) == [target.id])
        viewModel.disconnect()
        let start = StartSavedCallIntent(target: target); start.owner = owner
        _ = try await start.perform()
        #expect(viewModel.activeGroupID != nil)
        // Deleting the person ends the call with them.
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.activeGroupID == nil)
        #expect(try await query.entities(for: [target.id]).isEmpty)
        await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
        let end = EndCurrentCallIntent(); end.owner = owner
        _ = try await end.perform()
        #expect(viewModel.activeGroupID == nil)
    }
}
