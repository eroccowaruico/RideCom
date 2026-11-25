import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct MicrophoneAuthorizationTests {
    enum CallEntry: CaseIterable { case savedGroup, newGroup, invitation }

    @Test(arguments: CallEntry.allCases, [false, true])
    func callWaitsForMicrophonePermissionAndKeepsSavedGroups(entry: CallEntry, grantsPermission: Bool) async throws {
        let gate = ManualAsyncGate()
        var requested = false
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requested = true
            await gate.wait()
            return grantsPermission
        }, callMicrophonePermission: { .undetermined })
        let model = harness.viewModel
        defer { model.disconnect() }
        let previous = model.selectedGroup?.id
        let groupID: UUID
        switch entry {
        case .newGroup:
            groupID = UUID()
            #expect(model.createTalkGroup(name: "Microphone test", id: groupID))
        case .savedGroup:
            groupID = try #require(model.groups.first?.id)
            model.openDestination(.group(groupID))
        case .invitation:
            groupID = UUID()
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("inviter"),
                credential: .init(groupID: groupID, secret: "test-key"),
                groupName: "Invited group", inviterMemberID: "inviter")
            try model.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        }
        #expect(harness.groupStore.loadGroups().contains { $0.id == groupID })
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(model.selectedGroup?.id == previous)
        #expect(!harness.audioSessionBackend.activeValues.contains(true))

        await gate.release()
        await AppTestSupport.waitUntil { model.isAudioReady || model.showsCallMicrophonePermissionAlert }
        #expect((harness.callSession.connectedGroup?.id == groupID) == grantsPermission)
        #expect(model.showsCallMicrophonePermissionAlert != grantsPermission)
        #expect((model.callToPresentAfterPermission == model.currentCallReference) == grantsPermission)
        #expect(harness.groupStore.loadGroups().contains { $0.id == groupID })
    }

    @Test func deniedAndBackgroundUndeterminedDoNotAskOrConnect() throws {
        var state = CallMicrophonePermission.denied
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            Issue.record("The microphone request must not be presented.")
            return false
        }, callMicrophonePermission: { state })
        let model = harness.viewModel
        defer { model.disconnect() }
        let groupID = try #require(model.groups.first?.id)
        #expect(model.openDestination(.group(groupID)) == .blocked)
        #expect(model.showsCallMicrophonePermissionAlert)
        model.showsCallMicrophonePermissionAlert = false
        state = .undetermined
        let background = model.requestCallStart(
            to: .group(groupID), accountAccessID: model.accountAccessID, allowsMicrophonePrompt: false)
        guard case .blocked = background else { Issue.record("A background operation tried to start."); return }
        #expect(harness.callSession.connectedGroup == nil)
        #expect(!model.showsCallMicrophonePermissionAlert)
    }

    @Test(arguments: [false, true])
    func permissionRequestCannotStartAfterItsCallContextEnds(signsOut: Bool) async throws {
        let gate = ManualAsyncGate()
        var requested = false
        let harness = AppTestSupport.makeHarness(requestMicrophoneAccess: {
            requested = true
            await gate.wait()
            return true
        }, callMicrophonePermission: { .undetermined })
        let model = harness.viewModel
        defer { model.disconnect() }
        let id = try #require(model.regularGroups.first?.id)
        let start = model.requestCallStart(to: .group(id), accountAccessID: model.accountAccessID)
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        if signsOut { model.accountSession.signOut() } else { model.disconnect() }
        await gate.release()
        #expect(await start.startedCall() == nil)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(model.callToPresentAfterPermission == nil)
    }

    @Test(arguments: [false, true])
    func permissionCompletesBeforeActivationAndCapture(recording: Bool) async throws {
        let gate = ManualAsyncGate(); var requested = false
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requested = true; await gate.wait(); return true
        }), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck(); viewModel.disconnect() }
        if recording {
            #expect(viewModel.startAudioCheck())
        } else {
            viewModel.selectGroup(try #require(viewModel.groups.first))
        }
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        #expect(!harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
        #expect(!viewModel.isAudioReady && !viewModel.isCallMediaStarted)
        await gate.release()
        await AppTestSupport.waitUntil { recording ? viewModel.audioCheckPhase == .recording : viewModel.isAudioReady }
        #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
    }

    @Test(arguments: [false, true])
    func denialReportsFailureWithoutOpeningMicrophone(recording: Bool) async throws {
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: { false }),
            viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck(); viewModel.disconnect() }
        if recording {
            #expect(viewModel.startAudioCheck())
        } else {
            viewModel.selectGroup(try #require(viewModel.groups.first))
        }
        await AppTestSupport.waitUntil {
            recording ? viewModel.audioCheckPhase == .failed : viewModel.audioErrorMessage != nil
        }
        #expect(
            (recording ? viewModel.audioCheckStatusMessage : viewModel.audioErrorMessage)
                == IntercomViewModel.microphoneAccessRequiredMessage)
        #expect(recording ? viewModel.audioCheckPhase == .failed : viewModel.standardCallStatus == .audioUnavailable)
        #expect(!harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
        #expect(!viewModel.isAudioReady && harness.callSession.startMediaCallCount == 0)
    }

    @Test(arguments: [false, true])
    func cancellationDuringPermissionCannotStartFromALateGrant(recording: Bool) async throws {
        let gate = ManualAsyncGate(); var requested = false, completed = false
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requested = true; await gate.wait(); completed = true; return true
        }), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck(); viewModel.disconnect() }
        if recording {
            #expect(viewModel.startAudioCheck())
        } else {
            viewModel.selectGroup(try #require(viewModel.groups.first))
        }
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        let pending = recording ? viewModel.audioCheckTask : viewModel.audioStartTask
        if recording { viewModel.cancelAudioCheck() } else { viewModel.disconnect() }
        await gate.release()
        await pending?.value
        #expect(completed)
        #expect(!harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
        #expect(
            viewModel.audioCheckPhase == .idle && viewModel.audioStartTask == nil
                && viewModel.callDisconnectDeadline == nil)
    }

    @Test func permissionArrivingAfterTheDeadlineEndsTheCallWithoutOpeningInput() async throws {
        let gate = ManualAsyncGate(); var requested = false, completed = false, now = Date()
        let
            harness = AppTestSupport.makeHarness(
                enforceCallAccess: false, callAccessNow: { now },
                requestMicrophoneAccess: {
            requested = true; await gate.wait(); completed = true; return true
        }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        let pending = viewModel.audioStartTask
        now = try #require(viewModel.callDisconnectDeadline).addingTimeInterval(1)
        await gate.release()
        await pending?.value
        #expect(completed && viewModel.audioStartTask == nil)
        #expect(viewModel.callDisconnectDeadline == nil && viewModel.activeGroupID == nil)
        #expect(harness.inputBackend.startCount == 0 && !harness.audioSessionBackend.activeValues.contains(true))
    }

    @Test func aLateGrantCannotStopOrReplaceTheNewCall() async throws {
        let gate = ManualAsyncGate(); var requests = 0, completed = false
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requests += 1
            if requests == 1 { await gate.wait(); completed = true }
            return true
        }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = try #require(viewModel.groups.first), second = try #require(viewModel.groups.last)
        try #require(first.id != second.id)
        viewModel.selectGroup(first)
        await AppTestSupport.waitUntil { requests == 1 }
        let pending = viewModel.audioStartTask
        viewModel.disconnect(); viewModel.selectGroup(second)
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady && harness.inputBackend.startCount == 1)
        await gate.release()
        await pending?.value
        #expect(completed)
        #expect(viewModel.isAudioReady && viewModel.activeGroupID == second.id && harness.inputBackend.startCount == 1)
        #expect(harness.audioSessionBackend.activeValues.last == true)
    }
}
