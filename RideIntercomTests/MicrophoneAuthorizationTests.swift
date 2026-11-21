import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct MicrophoneAuthorizationTests {
    @Test(arguments: [false, true])
    func permissionCompletesBeforeActivationAndCapture(recording: Bool) async throws {
        let gate = ManualAsyncGate(); var requested = false
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requested = true; await gate.wait(); return true
        }), vm = h.viewModel
        defer { vm.cancelAudioCheck(); vm.disconnect() }
        if recording { #expect(vm.startAudioCheck()) } else { vm.selectGroup(try #require(vm.groups.first)) }
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        #expect(!h.audioSessionBackend.activeValues.contains(true))
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(!vm.isAudioReady && !vm.isCallMediaStarted)
        await gate.release()
        await AppTestSupport.waitUntil { recording ? vm.audioCheckPhase == .recording : vm.isAudioReady }
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
    }

    @Test(arguments: [false, true])
    func denialReportsFailureWithoutOpeningMicrophone(recording: Bool) async throws {
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: { false }), vm = h.viewModel
        defer { vm.cancelAudioCheck(); vm.disconnect() }
        if recording { #expect(vm.startAudioCheck()) } else { vm.selectGroup(try #require(vm.groups.first)) }
        await AppTestSupport.waitUntil { recording ? vm.audioCheckPhase == .failed : vm.audioErrorMessage != nil }
        #expect((recording ? vm.audioCheckStatusMessage : vm.audioErrorMessage) == IntercomViewModel.microphoneAccessRequiredMessage)
        #expect(recording ? vm.audioCheckPhase == .failed : vm.standardCallStatus == .audioUnavailable)
        #expect(!h.audioSessionBackend.activeValues.contains(true))
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(!vm.isAudioReady && h.callSession.startMediaCallCount == 0)
    }

    @Test(arguments: [false, true])
    func cancellationDuringPermissionCannotStartFromALateGrant(recording: Bool) async throws {
        let gate = ManualAsyncGate(); var requested = false, completed = false
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requested = true; await gate.wait(); completed = true; return true
        }), vm = h.viewModel
        defer { vm.cancelAudioCheck(); vm.disconnect() }
        if recording { #expect(vm.startAudioCheck()) } else { vm.selectGroup(try #require(vm.groups.first)) }
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        let pending = recording ? vm.audioCheckTask : vm.audioStartTask
        if recording { vm.cancelAudioCheck() } else { vm.disconnect() }
        await gate.release()
        await pending?.value
        #expect(completed)
        #expect(!h.audioSessionBackend.activeValues.contains(true))
        #expect(h.inputBackend.startCount == 0 && h.outputBackend.startCount == 0)
        #expect(vm.audioCheckPhase == .idle && vm.audioStartTask == nil && vm.callDisconnectDeadline == nil)
    }

    @Test func permissionArrivingAfterTheDeadlineEndsTheCallWithoutOpeningInput() async throws {
        let gate = ManualAsyncGate(); var requested = false, completed = false, now = Date()
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, callAccessNow: { now }, requestMicrophoneAccess: {
            requested = true; await gate.wait(); completed = true; return true
        }), vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first))
        await AppTestSupport.waitUntil { requested }
        #expect(requested)
        let pending = vm.audioStartTask
        now = try #require(vm.callDisconnectDeadline).addingTimeInterval(1)
        await gate.release()
        await pending?.value
        #expect(completed && vm.audioStartTask == nil)
        #expect(vm.callDisconnectDeadline == nil && vm.activeGroupID == nil)
        #expect(h.inputBackend.startCount == 0 && !h.audioSessionBackend.activeValues.contains(true))
    }

    @Test func aLateGrantCannotStopOrReplaceTheNewCall() async throws {
        let gate = ManualAsyncGate(); var requests = 0, completed = false
        let h = AppTestSupport.makeHarness(enforceCallAccess: false, requestMicrophoneAccess: {
            requests += 1
            if requests == 1 { await gate.wait(); completed = true }
            return true
        }), vm = h.viewModel
        defer { vm.disconnect() }
        let first = try #require(vm.groups.first), second = try #require(vm.groups.last)
        try #require(first.id != second.id)
        vm.selectGroup(first)
        await AppTestSupport.waitUntil { requests == 1 }
        let pending = vm.audioStartTask
        vm.disconnect(); vm.selectGroup(second)
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady && h.inputBackend.startCount == 1)
        await gate.release()
        await pending?.value
        #expect(completed)
        #expect(vm.isAudioReady && vm.activeGroupID == second.id && h.inputBackend.startCount == 1)
        #expect(h.audioSessionBackend.activeValues.last == true)
    }
}
