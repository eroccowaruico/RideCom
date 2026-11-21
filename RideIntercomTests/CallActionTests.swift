import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct CallActionTests {
    enum ExternalEntry: String, CaseIterable, Sendable { case widget, shortcut, watch }

    @Test(arguments: ExternalEntry.allCases)
    func refusedExternalStartLeavesTheSavedDirectoryAndCurrentCallAlone(entry: ExternalEntry) async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let user = try #require(viewModel.savedRemoteUsers.first)
        let target = try #require(owner.callTargets.first { $0.destination == .user(user.id) }?.entity)
        let group = try #require(viewModel.regularGroups.first)

        try #require(viewModel.startCall(to: .group(group.id), accountAccessID: viewModel.accountAccessID))
        let reference = viewModel.currentCallReference
        let selection = viewModel.selectedGroup
        let snapshot = harness.groupStore.snapshot
        try #require(viewModel.existingDirectCall(for: user.id) == nil)

        switch entry {
        case .widget:
            let intent = OpenCallControlIntent(destinationID: target.id); intent.actions = owner
            await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        case .shortcut:
            let intent = StartSavedCallIntent(target: target); intent.owner = owner
            await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        case .watch:
            let reply = await owner.handleWatchRequest(.init(.startRemote(target.id), snapshot: owner.watchSnapshot()))
            #expect(reply.problem == .denied)
        }
        #expect(viewModel.groupErrorMessage?.contains("End the current call") == true)
        #expect(viewModel.currentCallReference == reference && viewModel.selectedGroup == selection)
        let storageUnchanged = harness.groupStore.snapshot == snapshot
        #expect(storageUnchanged)
        #expect(viewModel.existingDirectCall(for: user.id) == nil)
    }

    @Test func explicitDestinationDoesNotDependOnTheBrowsedGroup() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.startCall(to: .group(first.id), accountAccessID: viewModel.accountAccessID))
        let reference = viewModel.currentCallReference
        viewModel.selectGroup(second)
        #expect(viewModel.activeGroupID == first.id && viewModel.selectedGroup?.id == second.id)
        #expect(viewModel.startCall(to: .group(first.id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.activeGroupID == first.id)
        #expect(viewModel.currentCallReference == reference)
    }

    @Test func oldEndAndMuteCannotControlADifferentCallOrAReconnection() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.startCall(to: .group(first.id), accountAccessID: viewModel.accountAccessID))
        let old = viewModel.currentCallReference
        #expect(viewModel.startCall(to: .group(second.id), accountAccessID: viewModel.accountAccessID))
        #expect(!viewModel.endCall(old))
        #expect(viewModel.activeGroupID == second.id)
        #expect(!viewModel.setCallMuted(true, for: old))
        #expect(!viewModel.isMuted)
        #expect(viewModel.endCall(viewModel.currentCallReference))
        #expect(viewModel.startCall(to: .group(first.id), accountAccessID: viewModel.accountAccessID))
        #expect(!viewModel.endCall(old))
        #expect(viewModel.activeGroupID == first.id)
    }

    @Test func explicitMuteIsIdempotentAndIdleIntentCannotAffectANewCall() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let idle = viewModel.currentCallReference
        #expect(viewModel.setCallMuted(true, for: idle))
        #expect(viewModel.setCallMuted(true, for: idle))
        #expect(viewModel.isMuted && harness.callSession.localMuteValues == [true])
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        let current = viewModel.currentCallReference
        #expect(!viewModel.setCallMuted(false, for: idle))
        #expect(viewModel.isMuted)
        #expect(viewModel.setCallMuted(false, for: current))
        #expect(viewModel.setCallMuted(false, for: current))
        #expect(!viewModel.isMuted && harness.callSession.localMuteValues == [true, false])
    }

    @Test func manualRestartAfterTransportStopsInvalidatesThePreviousCall() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let destination = CallDestination.group(viewModel.groups[0].id)
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        let old = viewModel.currentCallReference
        viewModel.handleTransportEvent(.disconnected)
        #expect(viewModel.startCall(to: destination, accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.currentCallReference != old)
        #expect(!viewModel.endCall(old))
        #expect(!viewModel.setCallMuted(true, for: old))
        #expect(viewModel.hasAnyActiveGroupConnection && !viewModel.isMuted)
    }

    @Test func deletingAContactEndsTheirCallAndItCannotStartAgain() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: group.id, groupName: group.name, groupSecret: "group-key", inviterMemberID: "friend")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.startCall(to: .user(user.id), accountAccessID: viewModel.accountAccessID))
        let direct = try #require(viewModel.selectedGroup)
        let call = viewModel.currentCallReference
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.activeGroupID == nil)
        #expect(!viewModel.endCall(call))
        #expect(!viewModel.startCall(to: .user(user.id), accountAccessID: viewModel.accountAccessID))
        #expect(!viewModel.startCall(to: .group(direct.id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.activeGroupID == nil)
        #expect(!viewModel.groups.contains(where: { $0.id == direct.id }))
    }

    @Test func staleStartCannotCrossLoginGenerationEvenForTheSameUser() throws {
        let fixture = AccountFixture(); defer { fixture.remove() }
        fixture.signIn()
        let old = try harness(account: fixture.session)
        let destination = CallDestination.group(old.viewModel.groups[0].id)
        let access = old.viewModel.accountAccessID
        fixture.session.signOut(); fixture.signIn()
        var restored = old.viewModel.groups
        for index in restored.indices { restored[index].accessSecret = "group-key" }
        let fresh = AppTestSupport.makeHarness(accountSession: fixture.session, groups: restored)
        defer { fresh.viewModel.disconnect() }
        #expect(!fresh.viewModel.startCall(to: destination, accountAccessID: access))
        #expect(fresh.viewModel.activeGroupID == nil)
        #expect(!old.viewModel.startCall(to: destination, accountAccessID: access))
        #expect(old.viewModel.activeGroupID == nil)
        #expect(fresh.viewModel.startCall(to: destination, accountAccessID: fresh.viewModel.accountAccessID))
    }

    private func harness(account: AppleAccountSession? = nil) throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(
            name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        let second = try IntercomGroup(
            name: "Second", members: [.init(id: "local", displayName: "You")], accessSecret: "second-key")
        return AppTestSupport.makeHarness(accountSession: account, groups: [first, second])
    }
}
