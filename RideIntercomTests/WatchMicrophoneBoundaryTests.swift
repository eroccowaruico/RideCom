import AppIntents
import Foundation
import Observation
import Synchronization
import Testing
@testable import RideIntercom

@MainActor struct WatchMicrophoneBoundaryTests {
    @Test func watchSnapshotDoesNotObserveRecordingProgressButPublishesFinalStateAndSession() throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        let session = UUID(), now = Date(timeIntervalSince1970: 1_000)
        viewModel.audioCheckWatchSessionID = session
        viewModel.audioCheckPhase = .recording
        viewModel.audioCheckRecordedFrameCount = 480
        viewModel.audioCheckRecordedNonzeroSamples = 100
        let notifications = Mutex(0)
        let initial = withObservationTracking {
            owner.watchSnapshot(now: now)
        } onChange: {
            notifications.withLock { $0 += 1 }
        }
        let initialCheck = try #require(initial.audioCheck)
        #expect(initialCheck.sessionID == session && initialCheck.phase == .recording)
        #expect(initialCheck.recordedFrames == 0 && initialCheck.nonzeroSamples == 0)

        viewModel.audioCheckRecordedFrameCount = 240_000
        viewModel.audioCheckRecordedNonzeroSamples = 12_345
        let progress = owner.watchSnapshot(now: now)
        #expect(
            notifications.withLock { $0 } == 0,
            "Recording progress must not invalidate the real snapshot observation")
        #expect(progress == initial)
        #expect(!progress.needsPublication(after: initial))
        #expect(
            viewModel.audioCheckRecordedFrameCount == 240_000 && viewModel.audioCheckRecordedNonzeroSamples == 12_345,
                "The phone retains its actual recording counters")

        viewModel.audioCheckPhase = .preparing
        #expect(notifications.withLock { $0 } == 1, "The phase transition must invalidate the snapshot observation")
        let completedRecording = owner.watchSnapshot(now: now)
        let finalCheck = try #require(completedRecording.audioCheck)
        #expect(finalCheck.recordedFrames == 240_000 && finalCheck.nonzeroSamples == 12_345)
        #expect(completedRecording.needsPublication(after: progress))

        let phaseNotifications = Mutex(0)
        _ = withObservationTracking { owner.watchSnapshot(now: now) } onChange: {
            phaseNotifications.withLock { $0 += 1 }
        }
        viewModel.audioCheckRecordedNonzeroSamples = 12_346
        #expect(phaseNotifications.withLock { $0 } == 1, "Final counters are observable outside recording")
        let updatedFinal = owner.watchSnapshot(now: now)
        #expect(updatedFinal.audioCheck?.nonzeroSamples == 12_346)
        #expect(updatedFinal.needsPublication(after: completedRecording))

        viewModel.audioCheckWatchSessionID = UUID()
        let nextSession = owner.watchSnapshot(now: now)
        #expect(nextSession.needsPublication(after: updatedFinal))
    }
    @Test func holdClosesOnInactiveAndCannotResumeWithoutNewPress() {
        var state = WatchMicrophoneIntent()
        #expect(!state.isOn)
        state.request(true)
        #expect(state.isOn)
        state.setScene(.inactive)
        #expect(!state.isOn, "Wrist dimming closes push-to-talk")
        state.request(true)
        #expect(!state.isOn, "Inactive state cannot initiate a new transmission")
        state.setScene(.active)
        #expect(!state.isOn, "Returning active must not reopen the microphone")
        state.request(true)
        #expect(state.isOn)
        state.request(false)
        #expect(!state.isOn)
    }

    @Test func backgroundAndForceCloseRequireANewPress() {
        var state = WatchMicrophoneIntent()
        state.request(true)
        state.setScene(.background)
        #expect(!state.isOn)
        state.request(true)
        #expect(!state.isOn)
        state.setScene(.active)
        #expect(!state.isOn)
        state.request(true)
        #expect(state.isOn)
        state.close()
        #expect(!state.isOn)
        state.setScene(.inactive)
        state.setScene(.active)
        #expect(!state.isOn)
    }

    @Test func watchRouteIgnoresSavedPhoneMuteAndRejectsPhoneControls() async throws {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.applyLocalMute(true)
        #expect(viewModel.startCall(to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID))
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        viewModel.selectWatchAudioRoute()
        let reference = viewModel.currentCallReference
        let surface = try #require(owner.currentLivePresentation)
        #expect(!surface.canControlMicrophone)
        #expect(!surface.isMuted, "The saved phone mute is not the Watch microphone state")
        #expect(
            harness.callSession.localMuteValues.last == false,
            "RTC must accept Watch audio despite the saved phone mute")
        #expect(!viewModel.setCallMuted(false, for: reference))
        #expect(!owner.setCallSurfaceMuted(false, reference: surface.reference))
        let intent = SetCallMutedIntent(muted: false); intent.owner = owner
        await #expect(throws: CallIntentError.self) { _ = try await intent.perform() }
        #expect(viewModel.isMuted, "The phone preference must survive Watch use")
        viewModel.disconnect()
        #expect(viewModel.isMuted && !viewModel.isUsingWatchAudio)
        #expect(viewModel.setCallMuted(false, for: viewModel.currentCallReference))
        #expect(!viewModel.isMuted)
    }

    @Test func initialWatchStartRejectsStaleWidgetMuteWithoutOpeningPhoneInput() throws {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.startCall(
            to: .group(viewModel.groups[0].id), accountAccessID: viewModel.accountAccessID, source: .watchAudio))
        #expect(!viewModel.setCallMuted(true, for: viewModel.currentCallReference))
        #expect(harness.inputBackend.startCount == 0)
        #expect(!viewModel.isMuted)
    }
}
