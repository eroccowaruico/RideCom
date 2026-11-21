import AVFAudio
import AudioMixer
import CallControl
import Foundation
import SessionManager
import Testing

@testable import RideIntercom

extension AudioActivationTests {
  #if os(iOS)
    @Test func nativeConfigurationChangeRestartsAnActiveCallOnTheSameDevices() async throws {
      let engine = AVAudioEngine()
      let harness = AppTestSupport.makeHarness(outputEngine: engine)
      let viewModel = harness.viewModel
      defer { viewModel.disconnect() }
      viewModel.setSoundIsolationEnabled(false)
      viewModel.selectGroup(try #require(viewModel.groups.first))
      harness.callSession.authenticate(["member-108"])
      await AppTestSupport.waitUntil { viewModel.isAudioReady }
      try #require(viewModel.isAudioReady)
      let call = viewModel.currentCallReference
      let deadline = viewModel.callDisconnectDeadline
      try #require(viewModel.setCallMuted(true, for: call))
      let originalOutput = harness.audioSessionBackend.current.currentOutput
      let starts = harness.outputBackend.startCount

      func postConfigurationChange(for engine: AVAudioEngine) async {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
          DispatchQueue.main.async { finished.resume() }
        }
      }

      await postConfigurationChange(for: AVAudioEngine())
      #expect(harness.outputBackend.startCount == starts && viewModel.isAudioReady)
      harness.audioSessionBackend.current.currentOutput = .builtInSpeaker
      await postConfigurationChange(for: engine)
      #expect(harness.outputBackend.startCount == starts && viewModel.isAudioReady)
      harness.audioSessionBackend.current.currentOutput = originalOutput

      await postConfigurationChange(for: engine)
      await AppTestSupport.waitUntil {
        harness.outputBackend.startCount > starts && viewModel.isAudioReady
      }
      #expect(harness.outputBackend.startCount == starts + 1 && viewModel.isAudioReady)
      #expect(
        viewModel.currentCallReference == call && viewModel.callDisconnectDeadline == deadline)
      #expect(viewModel.effectiveInputMuted)

      viewModel.handleAudioSessionRuntimeEvent(
        .snapshotChanged(
          .init(reason: .interruptionBegan, snapshot: harness.audioSessionBackend.current)))
      await postConfigurationChange(for: engine)
      #expect(harness.outputBackend.startCount == starts + 1)
      #expect(viewModel.isAudioPausedForDeviceChange && !viewModel.isAudioReady)
    }

    @Test func deniedPermissionDuringNativeReconfigurationLeavesTheCallReadyForExplicitResume()
      async throws {
      let engine = AVAudioEngine()
      var microphoneAllowed = true
      let harness = AppTestSupport.makeHarness(
        outputEngine: engine, requestMicrophoneAccess: { microphoneAllowed })
      let viewModel = harness.viewModel
      defer { viewModel.disconnect() }
      viewModel.setSoundIsolationEnabled(false)
      viewModel.selectGroup(try #require(viewModel.groups.first))
      harness.callSession.authenticate(["member-108"])
      await AppTestSupport.waitUntil { viewModel.isAudioReady }
      try #require(viewModel.isAudioReady)
      let call = viewModel.currentCallReference
      let deadline = viewModel.callDisconnectDeadline
      let starts = harness.inputBackend.startCount

      microphoneAllowed = false
      NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
      await AppTestSupport.waitUntil {
        viewModel.audioErrorMessage == IntercomViewModel.microphoneAccessRequiredMessage
      }
      #expect(viewModel.audioPauseError == IntercomViewModel.microphoneAccessRequiredMessage)
      #expect(viewModel.callStatus(for: call.groupID) == .audioPaused)
      #expect(
        viewModel.currentCallReference == call && viewModel.callDisconnectDeadline == deadline)
      #expect(harness.inputBackend.startCount == starts && !viewModel.isAudioReady)

      microphoneAllowed = true
      viewModel.resumeAudioAfterDeviceChange()
      await AppTestSupport.waitUntil { viewModel.isAudioReady }
      #expect(harness.inputBackend.startCount == starts + 1 && viewModel.isAudioReady)
      #expect(viewModel.audioErrorMessage == nil && viewModel.audioRouteNotice == nil)
      #expect(
        viewModel.currentCallReference == call && viewModel.callDisconnectDeadline == deadline)
    }
  #endif

  @Test(arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset])
  func nativeInterruptionPausesActiveCallUntilExplicitResume(
    reason: AudioSessionSnapshotChangeReason
  ) async {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    viewModel.setSoundIsolationEnabled(false)
    viewModel.selectGroup(viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    let deadline = viewModel.callDisconnectDeadline
    let group = viewModel.activeGroupID
    let starts = harness.inputBackend.startCount
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: reason, snapshot: harness.audioSessionBackend.current)))
    #expect(!viewModel.isAudioReady && viewModel.isAudioPausedForDeviceChange)
    #expect(viewModel.audioRouteNotice?.contains("interrupted") == true)
    #expect(viewModel.activeGroupID == group && viewModel.callDisconnectDeadline == deadline)
    #expect(harness.inputBackend.stopCount > 0 && harness.outputBackend.stopCount > 0)
    #expect(viewModel.audioPipeline.snapshot.busIDs.isEmpty)
    var restored = harness.audioSessionBackend.current
    restored.currentOutput = .builtInSpeaker
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: .interruptionEnded(shouldResume: true), snapshot: restored)))
    harness.callSession.authenticate(["member-108"])
    await Task.yield()
    #expect(!viewModel.isAudioReady && viewModel.audioStartTask == nil)
    #expect(harness.inputBackend.startCount == starts)
    viewModel.resumeAudioAfterDeviceChange()
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(
      viewModel.isAudioReady && !viewModel.isAudioPausedForDeviceChange
        && viewModel.audioRouteNotice == nil)
    #expect(viewModel.callDisconnectDeadline == deadline)
    viewModel.disconnect()
    _ = await viewModel.audioSessionManager.requestActive(false).value
  }

  @Test(
    arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset],
    [true, false])
  func nativeInterruptionCancelsPendingActivation(
    reason: AudioSessionSnapshotChangeReason, checking: Bool
  ) async {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    let gate = ManualAsyncGate()
    viewModel.setSoundIsolationEnabled(false)
    harness.audioSessionBackend.activationGate = gate
    if checking {
      viewModel.startAudioCheck()
    } else {
      viewModel.selectGroup(viewModel.groups[0])
      harness.callSession.authenticate(["member-108"])
    }
    await gate.waitForEntry()
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: reason, snapshot: harness.audioSessionBackend.current)))
    #expect(viewModel.audioCheckPhase == .idle && viewModel.audioStartTask == nil)
    if checking {
      #expect(viewModel.audioCheckStatusMessage.contains("interrupted"))
    } else {
      #expect(
        viewModel.isAudioPausedForDeviceChange
          && viewModel.audioRouteNotice?.contains("interrupted") == true)
    }
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(
        .init(
          reason: .interruptionEnded(shouldResume: true),
          snapshot: harness.audioSessionBackend.current)))
    await gate.release()
    await AppTestSupport.waitUntil { viewModel.audioStartTask == nil }
    _ = await viewModel.audioSessionManager.requestActive(false).value
    #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
    #expect(harness.callSession.startMediaCallCount == 0 && !viewModel.isAudioReady)
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
    viewModel.disconnect()
  }

  @Test(arguments: [AudioSessionSnapshotChangeReason.interruptionBegan, .mediaServicesReset])
  func nativeInterruptionStopsRecordingCheckWithoutAutomaticRestart(
    reason: AudioSessionSnapshotChangeReason
  ) async {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: reason, snapshot: harness.audioSessionBackend.current)))
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
    #expect(harness.inputBackend.stopCount == 1 && harness.outputBackend.stopCount == 1)
    #expect(viewModel.audioCheckStatusMessage.contains("interrupted"))
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(
        .init(
          reason: .interruptionEnded(shouldResume: true),
          snapshot: harness.audioSessionBackend.current)))
    _ = await viewModel.audioSessionManager.requestActive(false).value
    #expect(viewModel.audioCheckPhase == .idle)
    #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
    viewModel.cancelAudioCheck()
  }

  @Test func interruptionBeforePeerAuthenticationRequiresExplicitResume() async {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    viewModel.setSoundIsolationEnabled(false)
    viewModel.selectGroup(viewModel.groups[0])
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(
        .init(reason: .interruptionBegan, snapshot: harness.audioSessionBackend.current)))
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(
        .init(
          reason: .interruptionEnded(shouldResume: true),
          snapshot: harness.audioSessionBackend.current)))
    harness.callSession.authenticate(["member-108"])
    await Task.yield()
    #expect(
      viewModel.isAudioPausedForDeviceChange && !viewModel.isAudioReady
        && viewModel.audioStartTask == nil)
    #expect(harness.inputBackend.startCount == 0 && harness.callSession.startMediaCallCount == 0)
    viewModel.resumeAudioAfterDeviceChange()
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(viewModel.isAudioReady)
    viewModel.disconnect()
    _ = await viewModel.audioSessionManager.requestActive(false).value
  }
}
