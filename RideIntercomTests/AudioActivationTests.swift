import AVFAudio
import AudioMixer
import CallControl
import Foundation
import SessionManager
import Testing

@testable import RideIntercom

@MainActor
struct AudioActivationTests {
  @Test func audioCheckLeavesOtherAudioAloneAndPreservesCallDuckingPreference() async throws {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    viewModel.setDuckOthersEnabled(true)
    for _ in 0..<2 {
      #expect(viewModel.startAudioCheck())
      await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
      #expect(viewModel.audioCheckPhase == .recording)
      #expect(!viewModel.audioInputCapture.configuration.voiceProcessing.otherAudioDuckingEnabled)
      #expect(!viewModel.audioInputCapture.configuration.voiceProcessing.voiceProcessingEnabled)
      #expect(viewModel.isDuckOthersEnabled)
      viewModel.cancelAudioCheck()
    }
    viewModel.selectGroup(try #require(viewModel.groups.first))
    viewModel.connectLocal()
    harness.callSession.authenticate(["member-108"])
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(viewModel.isAudioReady)
    #expect(viewModel.audioInputCapture.configuration.voiceProcessing.otherAudioDuckingEnabled)
    viewModel.disconnect()
  }

  @Test func audioCheckInitialRouteResolutionDoesNotCancelPreparation() async {
    let harness = AppTestSupport.makeHarness(groups: [])
    let gate = ManualAsyncGate()
    let viewModel = harness.viewModel
    harness.audioSessionBackend.activationGate = gate
    viewModel.startAudioCheck()
    await gate.waitForEntry()
    var resolved = harness.audioSessionBackend.current
    resolved.currentInput = resolved.availableInputs[1]
    harness.audioSessionBackend.current = resolved
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: .routeChanged(.categoryChanged), snapshot: resolved)))
    #expect(viewModel.audioCheckPhase == .preparing && viewModel.audioCheckOwnsAudioPipeline)
    await gate.release()
    await AppTestSupport.waitUntil {
      viewModel.audioCheckPhase == .recording || viewModel.audioCheckPhase == .idle
    }
    #expect(viewModel.audioCheckPhase == .recording)
    viewModel.cancelAudioCheck()
  }

  @Test func audioCheckUsesActualStartedRouteBeforeDelayedSetupNotification() async {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    let backend = harness.audioSessionBackend
    var resolved = backend.current
    resolved.currentInput = resolved.availableInputs[1]
    resolved.isActive = true
    harness.inputBackend.onStart = { [weak backend] in backend?.current = resolved }
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(
        .init(reason: .routeChanged(.routeConfigurationChanged), snapshot: backend.current)))
    #expect(viewModel.audioCheckPhase == .recording && viewModel.audioCheckOwnsAudioPipeline)
    viewModel.cancelAudioCheck()
  }

  @Test func staleRouteAfterStopCannotCancelTheNextAudioCheck() async {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    let backend = harness.audioSessionBackend
    var old = backend.current
    old.currentInput = old.availableInputs[1]
    var current = backend.current
    current.currentOutput = .builtInSpeaker
    current.isActive = true
    harness.inputBackend.onStart = { [weak backend] in backend?.current = current }
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    viewModel.cancelAudioCheck()
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: .routeChanged(.categoryChanged), snapshot: old)))
    #expect(viewModel.audioCheckPhase == .recording)
    #expect(viewModel.audioSessionSnapshot.currentInput.id == backend.current.currentInput.id)
    #expect(viewModel.audioSessionSnapshot.currentOutput.id == backend.current.currentOutput.id)
    viewModel.cancelAudioCheck()
  }

  @Test func ordinaryAudioCheckCannotStartThroughAWatchOwnedRoute() {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    viewModel.selectWatchAudioRoute()
    #expect(!viewModel.canStartAudioCheck)
    viewModel.startAudioCheck()
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
    #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
    #expect(
      viewModel.isUsingWatchAudio, "A normal start cannot silently replace another route owner")
    viewModel.disconnect()
  }

  @Test func actualPortSwitchDuringRecordingStillStopsAudioCheck() async {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    var changed = harness.audioSessionBackend.current
    changed.currentInput = changed.availableInputs[1]
    harness.audioSessionBackend.current = changed
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: .defaultInputChanged, snapshot: changed)))
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
  }

  @Test func configurationReportCannotHideActualPortSwitchDuringRecording() async throws {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    viewModel.startAudioCheck()
    await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
    var changed = harness.audioSessionBackend.current
    changed.currentInput = changed.availableInputs[1]
    harness.audioSessionBackend.current = changed
    var report = try #require(viewModel.lastAudioSessionConfigurationReport)
    report.snapshot = changed
    viewModel.handleAudioSessionRuntimeEvent(.configuration(report))
    viewModel.handleAudioSessionRuntimeEvent(
      .snapshotChanged(.init(reason: .defaultInputChanged, snapshot: changed)))
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
    viewModel.cancelAudioCheck()
  }

  @Test func callWaitsForActivationBeforeOpeningMedia() async {
    let harness = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    harness.audioSessionBackend.activationGate = gate
    harness.viewModel.setSoundIsolationEnabled(false)
    harness.viewModel.selectGroup(harness.viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await gate.waitForEntry()
    #expect(!harness.viewModel.isAudioReady)
    #expect(harness.inputBackend.startCount == 0)
    #expect(harness.outputBackend.startCount == 0)
    #expect(harness.callSession.startMediaCallCount == 0)
    await gate.release()
    await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
    #expect(harness.viewModel.isAudioReady)
    harness.viewModel.disconnect()
    _ = await harness.viewModel.audioSessionManager.requestActive(false).value
  }

  @Test func audioCheckWaitsForActivationAndCanCancelBeforeRecording() async {
    let harness = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    harness.audioSessionBackend.activationGate = gate
    harness.viewModel.startAudioCheck()
    await gate.waitForEntry()
    #expect(harness.viewModel.audioCheckPhase != .recording)
    #expect(harness.inputBackend.startCount == 0)
    #expect(harness.outputBackend.startCount == 0)
    #expect(!harness.viewModel.canStartAudioCheck)
    harness.viewModel.cancelAudioCheck()
    await gate.release()
    _ = await harness.viewModel.audioSessionManager.requestActive(false).value
    #expect(harness.viewModel.audioCheckPhase == .idle)
    #expect(harness.inputBackend.startCount == 0)
  }

  @Test(arguments: ["disconnect", "signout", "deadline"])
  func endedOrUnauthorizedCallCannotStartAfterLateActivation(ending: String) async {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    let harness = AppTestSupport.makeHarness(callAccessNow: { now })
    let gate = ManualAsyncGate()
    harness.audioSessionBackend.activationGate = gate
    harness.viewModel.setCallDisconnectInterval(.oneMinute)
    harness.viewModel.selectGroup(harness.viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await gate.waitForEntry()
    switch ending {
    case "signout": harness.viewModel.accountSession.signOut()
    case "deadline": now = now.addingTimeInterval(60)  // completion must check before the next tick
    default: harness.viewModel.disconnect()
    }
    await gate.release()
    await AppTestSupport.waitUntil { harness.viewModel.audioStartTask == nil }
    _ = await harness.viewModel.audioSessionManager.requestActive(false).value
    #expect(!harness.viewModel.isAudioReady)
    #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
    #expect(harness.callSession.startMediaCallCount == 0)
    #expect(!harness.audioSessionBackend.current.isActive)
    if ending == "deadline" {
      #expect(harness.viewModel.groupErrorMessage?.contains("timer") == true)
    }
    harness.viewModel.disconnect()
  }

}

extension AudioActivationTests {
  @Test func oldCallFailureCannotReplaceNewCallAndDuplicateRequestsShareOneStart() async {
    let harness = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    let viewModel = harness.viewModel
    viewModel.setSoundIsolationEnabled(false)
    harness.audioSessionBackend.activationGate = gate
    harness.audioSessionBackend.activationError = NSError(domain: "OldActivation", code: 1)
    viewModel.selectGroup(viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await gate.waitForEntry()
    viewModel.selectGroup(viewModel.groups[1])
    viewModel.connectLocal()
    harness.audioSessionBackend.activationError = nil
    harness.callSession.authenticate(["member-215"])
    let deadline = viewModel.callDisconnectDeadline
    harness.callSession.authenticate(["member-215"])
    viewModel.startAudioPipelineIfNeeded()
    viewModel.setSpeakerOutputEnabled(true)
    await gate.release()
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(viewModel.isAudioReady && viewModel.audioErrorMessage == nil)
    #expect(
      viewModel.activeGroupID == viewModel.groups[1].id
        && viewModel.callDisconnectDeadline == deadline)
    #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
    #expect(harness.callSession.startMediaCallCount == 1)
    #expect(
      harness.audioSessionBackend.appliedConfigurations.last?.options.contains(.defaultToSpeaker)
        == true)
    let requests = harness.audioSessionBackend.activeValues
    viewModel.setAudioSessionProfile(.voiceChat)
    await Task.yield()
    #expect(harness.audioSessionBackend.activeValues == requests)
    viewModel.disconnect()
    _ = await viewModel.audioSessionManager.requestActive(false).value
  }

  @Test func cancellingPreparingCheckCannotStopTheFollowingCall() async {
    let harness = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    let viewModel = harness.viewModel
    viewModel.setSoundIsolationEnabled(false)
    harness.audioSessionBackend.activationGate = gate
    viewModel.startAudioCheck(recordDuration: .milliseconds(1))
    await gate.waitForEntry()
    #expect(viewModel.audioCheckPhase == .preparing)
    viewModel.selectGroup(viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await gate.release()
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(viewModel.audioCheckPhase == .idle && !viewModel.audioCheckOwnsAudioPipeline)
    #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
    #expect(harness.audioSessionBackend.current.isActive)
    viewModel.disconnect()
    _ = await viewModel.audioSessionManager.requestActive(false).value
  }

  @Test func deviceLossCancelsPreparingCheckAndPendingCall() async {
    for checking in [true, false] {
      let harness = AppTestSupport.makeHarness()
      let gate = ManualAsyncGate()
      let viewModel = harness.viewModel
      harness.audioSessionBackend.activationGate = gate
      if checking {
        viewModel.startAudioCheck()
      } else {
        viewModel.selectGroup(viewModel.groups[0])
        harness.callSession.authenticate(["member-108"])
      }
      await gate.waitForEntry()
      viewModel.handleAudioSessionRuntimeEvent(
        .snapshotChanged(
          .init(
            reason: .routeChanged(.oldDeviceUnavailable),
            snapshot: harness.audioSessionBackend.current)))
      await gate.release()
      _ = await viewModel.audioSessionManager.requestActive(false).value
      #expect(harness.inputBackend.startCount == 0 && harness.outputBackend.startCount == 0)
      #expect(viewModel.audioCheckPhase == .idle && !viewModel.isAudioReady)
      if !checking { #expect(viewModel.isAudioPausedForDeviceChange) }
      viewModel.disconnect()
    }
  }

  @Test func accountModelsShareNativeActivationOrderingWithoutSharingCallState() async {
    let old = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    old.audioSessionBackend.activationGate = gate
    old.viewModel.selectGroup(old.viewModel.groups[0])
    old.callSession.authenticate(["member-108"])
    await gate.waitForEntry()
    old.viewModel.endAccountAccess()
    let current = AppTestSupport.makeHarness(audioSessionManager: old.viewModel.audioSessionManager)
    current.viewModel.setSoundIsolationEnabled(false)
    current.viewModel.selectGroup(current.viewModel.groups[0])
    current.callSession.authenticate(["member-108"])
    await gate.release()
    await AppTestSupport.waitUntil { current.viewModel.isAudioReady }
    #expect(old.inputBackend.startCount == 0 && old.callSession.startMediaCallCount == 0)
    #expect(current.viewModel.isAudioReady && old.audioSessionBackend.current.isActive)
    current.viewModel.disconnect()
    _ = await current.viewModel.audioSessionManager.requestActive(false).value
    #expect(!old.audioSessionBackend.current.isActive)
  }

  @Test func supersededActivationDoesNotOpenMediaButUnsupportedPlatformCan() async {
    let harness = AppTestSupport.makeHarness()
    let gate = ManualAsyncGate()
    let viewModel = harness.viewModel
    harness.audioSessionBackend.activationGate = gate
    viewModel.selectGroup(viewModel.groups[0])
    harness.callSession.authenticate(["member-108"])
    await gate.waitForEntry()
    let stopped = viewModel.audioSessionManager.requestActive(false)
    await gate.release()
    _ = await stopped.value
    await AppTestSupport.waitUntil { viewModel.audioStartTask == nil }
    #expect(harness.inputBackend.startCount == 0 && !viewModel.isAudioReady)
    harness.audioSessionBackend.activationError =
      AudioSessionManagerError.operationUnsupportedOnCurrentPlatform
    viewModel.setSoundIsolationEnabled(false)
    viewModel.startAudioPipelineIfNeeded()
    await AppTestSupport.waitUntil { viewModel.isAudioReady }
    #expect(viewModel.isAudioReady)
    viewModel.disconnect()
    _ = await viewModel.audioSessionManager.requestActive(false).value
  }

}
