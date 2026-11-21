import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct MicrophoneAuthorizationTests {
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
