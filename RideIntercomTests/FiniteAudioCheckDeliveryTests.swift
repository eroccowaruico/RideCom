import AudioCore
import Codec
import DynamicsProcessor
import RTC
import SessionManager
import Foundation
import Testing
@testable import RideIntercom

@Suite(.serialized)
@MainActor
struct FiniteAudioCheckDeliveryTests {
    private func blockActorBeyondLiveDeadline() { Thread.sleep(forTimeInterval: 0.15) }

    @Test func finiteRecordingSurvivesActorDelayAndTrimsAtFiveSeconds() async {
        var received: [PCMFrame] = []
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 5) { received.append($0) }
        defer { delivery.finish() }
        for index in 0..<236 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(index), format: format,
                                    capturedAt: Double(index * 1024) / 48_000,
                                    samples: [Float](repeating: Float(index), count: 1024)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { received.reduce(0) { $0 + $1.frameCount } == 240_000 }
        #expect(received.map(\.sequenceNumber) == Array(0..<235).map(UInt64.init))
        #expect(received.reduce(0) { $0 + $1.frameCount } == 240_000)
        #expect(received.last?.frameCount == 384)
        #expect(delivery.droppedFrameCount == 0)
    }

    @Test func viewModelRecordsAllFiveSecondsAndCanRestartAfterPlayback() async {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        for cycle in 0..<2 {
            viewModel.startAudioCheck()
            await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
            let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
            for index in 0..<236 {
                harness.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                    capturedAt: Double(cycle * 10) + Double(index * 1024) / 48_000,
                    samples: [Float](repeating: 0.2, count: 1024)))
            }
            blockActorBeyondLiveDeadline()
            await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .playing }
            #expect(viewModel.audioCheckRecordedFrameCount == 240_000)
            #expect(viewModel.inputFrameDelivery?.droppedFrameCount == 0)
            viewModel.completeAudioCheckPlayback()
            #expect(viewModel.audioCheckPhase == .completed && viewModel.canStartAudioCheck)
        }
    }

    @Test func delayedFirstInputGetsItsOwnBoundedWindowForAllFiveSeconds() async throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck() }
        #expect(viewModel.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        try #require(viewModel.audioCheckPhase == .recording)
        try await Task.sleep(for: .milliseconds(650))
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        harness.inputBackend.emit(.init(sequenceNumber: 0, format: format, capturedAt: 0,
                                  samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { viewModel.audioCheckRecordedFrameCount > 0 }
        try #require(viewModel.audioCheckRecordedFrameCount > 0)
        // The old preparation-relative 1.2 s deadline expires before these
        // remaining samples; the new first-input-relative deadline has not.
        try await Task.sleep(for: .milliseconds(650))
        try #require(viewModel.audioCheckPhase == .recording)
        for index in 1..<236 {
            harness.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index * 1024) / 48_000, samples: Array(repeating: 0.2, count: 1024)))
        }
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
            viewModel.audioCheckPhase == .playing || viewModel.audioCheckPhase == .failed
        }
        #expect(viewModel.audioCheckPhase == .playing)
        #expect(
            viewModel.audioCheckRecordedFrameCount == 240_000,
            "The shortened watchdog never shortens the five-second sample budget")
    }

    @Test func noInputAndInvalidInputStillFailWithinTheInitialDeadline() async throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck() }
        #expect(viewModel.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        try #require(viewModel.audioCheckPhase == .recording)
        viewModel.processAudioCheckInput(level: 0, frame: .init(sequenceNumber: 1, samples: []))
        viewModel.processAudioCheckInput(level: 0, frame: .init(sequenceNumber: 2, samples: [.nan]))
        #expect(viewModel.audioCheckRecordedFrameCount == 0, "Empty and invalid PCM cannot start recording")
        await AppTestSupport.waitUntil(timeout: .seconds(2)) { viewModel.audioCheckPhase == .failed }
        #expect(viewModel.audioCheckPhase == .failed)
        #expect(viewModel.audioCheckStatusMessage == "Incomplete microphone recording")
    }

    @Test func laterFramesDoNotExtendTheFirstInputDeadline() async throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck() }
        #expect(viewModel.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        try #require(viewModel.audioCheckPhase == .recording)
        harness.inputBackend.emit(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { viewModel.audioCheckRecordedFrameCount > 0 }
        try #require(viewModel.audioCheckRecordedFrameCount > 0)
        try await Task.sleep(for: .milliseconds(700))
        harness.inputBackend.emit(
            .init(sequenceNumber: 1, capturedAt: 1024.0 / 48_000, samples: Array(repeating: 0.2, count: 1024)))
        try await Task.sleep(for: .milliseconds(650))
        #expect(viewModel.audioCheckPhase == .failed, "A later frame must not restart the first-input watchdog")
    }

    @Test func cancelledWatchdogCannotStopTheNextRecordingGeneration() async throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        defer { viewModel.cancelAudioCheck() }
        #expect(viewModel.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        try #require(viewModel.audioCheckPhase == .recording)
        harness.inputBackend.emit(.init(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 1024)))
        await AppTestSupport.waitUntil { viewModel.audioCheckRecordedFrameCount > 0 }
        try #require(viewModel.audioCheckRecordedFrameCount > 0)
        try await Task.sleep(for: .milliseconds(650))
        viewModel.cancelAudioCheck()
        #expect(viewModel.startAudioCheck(recordDuration: .milliseconds(200)))
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        try #require(viewModel.audioCheckPhase == .recording)
        let newGeneration = viewModel.audioCheckGeneration
        try await Task.sleep(for: .milliseconds(700))
        #expect(viewModel.audioCheckGeneration == newGeneration)
        #expect(viewModel.audioCheckPhase == .recording,
            "The cancelled generation's deadline must not stop its successor")
    }

    @Test func finitePlaybackRetainsItsBoundedStartupAndDrainObservations() async {
        var count = 0
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let delivery = AudioFrameDelivery(finiteRecordingDuration: 6) { count += $0.frameCount }
        defer { delivery.finish() }
        for index in 0..<301 {
            delivery.yield(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index) * 0.02, samples: [Float](repeating: 0.2, count: 960)))
        }
        blockActorBeyondLiveDeadline()
        await AppTestSupport.waitUntil { count == 288_000 }
        #expect(count == 288_000)
        #expect(delivery.droppedFrameCount == 0)
    }

    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
    @Test func recordingObservationComparesNativeStereoOutputAfterRouteNegotiation() {
        let input = PCMFrame(
            sequenceNumber: 0, format: .intercomMixer, samples: [Float](repeating: 0.2, count: 240_000))
        var observation = AudioCheckValidationObservation(generation: UUID())
        observation.setInput([input])
        observation.appendOutput(.init(sequenceNumber: 0, format: .init(sampleRate: 48_000, channelCount: 2),
            samples: (0..<480_000).map { $0.isMultiple(of: 2) ? Float(0.3) : Float(0.1) }))
        let report = observation.record(phase: "Audio Check Complete", status: .init(
            droppedRenderFrames: 0, droppedInputFrames: 0, inputStopped: true, outputStopped: true,
            nativeBackends: true, watchRoute: false, engineRunning: false))
        #expect(report["comparison"] as? String == "measured")
        #expect(report["fullCoverage"] as? Bool == true)
        #expect(report["outputFrames"] as? Int == 240_000)
    }
    #endif

    @Test func recordingCheckUsesTheActualTransmitCodecAndDynamicsForAllFiveSeconds() async throws {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        viewModel.setSoundIsolationEnabled(false)
        viewModel.setRTCAudioFormatPreset(.mono16k)
        viewModel.setPreferredTransmitCodec(.mpeg4AACELD)
        viewModel.setVADSensitivity(.lowNoise)
        defer { viewModel.cancelAudioCheck() }
        for cycle in 0..<2 {
            viewModel.startAudioCheck()
            await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
            #expect(viewModel.audioPipeline.codecRuntimeReport.activeConfiguration.codec == .mpeg4AACELD)
            #expect(viewModel.audioPipeline.dynamicsRuntimeSnapshot != nil)
            let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
            for index in 0..<236 {
                let beginning = index * 1024
                let samples = (0..<1024).map { offset in
                    let sample = beginning + offset
                    if (96_000..<144_000).contains(sample) { return Float(0) }
                    let frequency = sample >= 235_200 ? 997.0 : 440.0
                    return Float(0.8 * sin(Double(sample) * 2 * .pi * frequency / 48_000))
                }
                harness.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: format,
                    capturedAt: Double(cycle * 10) + Double(beginning) / 48_000, samples: samples))
            }
            await AppTestSupport.waitUntil(timeout: .seconds(3)) { viewModel.audioCheckPhase == .playing }
            #expect(viewModel.audioCheckPhase == .playing)
            #expect(viewModel.audioCheckRecordedFrameCount == 80_000)
            #expect(viewModel.audioCheckOutputLevel > 0.02 && viewModel.audioCheckOutputLevel < 0.5,
                "The real transmit Dynamics unit must change the 0.566 RMS input before recording")
            let recorded = try #require(viewModel.audioCheckRecording).recordedFrames().flatMap(\.samples)
            let gap = Array(recorded[44_800..<46_400])
            #expect(AudioLevelMeter.rmsLevel(samples: gap) < 0.001,
                "VAD-suppressed time must remain at its original position as silence")
            let tail = Array(recorded.suffix(1600))
            let projection = tail.enumerated().reduce((0.0, 0.0)) { sum, item in
                let phase = 2 * Double.pi * 997 * Double(item.offset) / 16_000
                return (sum.0 + Double(item.element) * cos(phase), sum.1 + Double(item.element) * sin(phase))
            }
            #expect(hypot(projection.0, projection.1) / 1600 > 0.01,
                "The final 997Hz marker must survive both native DSP and codec drain")
            #expect(harness.callSession.startMediaCallCount == 0)
            viewModel.completeAudioCheckPlayback()
        }
    }

}

extension FiniteAudioCheckDeliveryTests {
    #if os(iOS) || os(macOS)
    @Test func nativeRecordingCheckUsesThePreparedGraphForTwoCycles() async throws {
        let harness = AppTestSupport.makeHarness(groups: [])
        let viewModel = makeNativeViewModel(harness)
        defer { viewModel.cancelAudioCheck(); viewModel.audioPipeline.onOutputFrame = nil }
        for _ in 0..<2 {
            var renderedFramesByRate: [Double: Int] = [:]
            #expect(viewModel.startAudioCheck())
            let output = viewModel.audioPipeline.onOutputFrame
            viewModel.audioPipeline.onOutputFrame = { frame in
                output?(frame)
                if viewModel.audioCheckPhase == .playing {
                    renderedFramesByRate[frame.format.sampleRate, default: 0] += frame.frameCount
                }
            }
            // Native device preparation and the five-second sample budget are
            // separate deadlines, as in the production first-input watchdog.
            await AppTestSupport.waitUntil(timeout: .seconds(8)) {
                viewModel.audioCheckRecordedFrameCount > 0 || viewModel.audioCheckPhase == .failed
            }
            await AppTestSupport.waitUntil(timeout: .seconds(7)) {
                viewModel.audioCheckPhase == .playing || viewModel.audioCheckPhase == .failed
            }
            #expect(
                viewModel.audioCheckPhase == .playing,
                """
                Native capture must reach five seconds: \(viewModel.audioCheckStatusMessage), \
                input=\(String(describing: viewModel.lastInputStreamOperationReport?.result)), \
                voice=\(String(describing: viewModel.lastVoiceProcessingOperationReport?.result))
                """
            )
            #expect(viewModel.audioCheckRecordedFrameCount == 240_000)
            await AppTestSupport.waitUntil(timeout: .seconds(7)) {
                viewModel.audioCheckPhase == .completed || viewModel.audioCheckPhase == .failed
            }
            #expect(viewModel.audioCheckPhase == .completed)
            let renderedDuration = renderedFramesByRate.reduce(0.0) { $0 + Double($1.value) / $1.key }
            #expect(
                renderedDuration >= 5,
                """
                Native output must render the complete five-second timeline; frames=\(renderedFramesByRate), \
                output=\(String(describing: viewModel.lastOutputStreamOperationReport))
                """
            )
            #expect(harness.callSession.startMediaCallCount == 0)
        }
    }
    private func makeNativeViewModel(_ harness: AppTestSupport.Harness) -> IntercomViewModel {
        IntercomViewModel(accountSession: harness.viewModel.accountSession, enforceCallAccess: false,
            callSession: harness.callSession, groupRepository: harness.viewModel.groupRepository,
            appSettingsStore: InMemoryAppSettingsStore(),
            internetSettingsStore: harness.viewModel.internetSettingsStore,
            localMemberIdentityStore: harness.viewModel.localMemberIdentityStore,
            invitationAuthority: harness.viewModel.invitationAuthority, requestMicrophoneAccess: { true },
            callTicker: NoOpCallTicker())
    }
    #endif

    #if os(iOS)
    @Test func nativeCallCaptureContinuesAfterPipelinePreparationAndRestart() async throws {
        // Account/control/transport and permission use fixtures. Native capture, DSP and
        // the shared hardware engine follow the ordinary call lifecycle.
        let harness = AppTestSupport.makeHarness(), viewModel = makeNativeViewModel(harness)
        defer { viewModel.disconnect() }
        for _ in 0..<2 {
            viewModel.selectGroup(try #require(viewModel.groups.first))
            viewModel.connectLocal()
            harness.callSession.authenticate(["member-108"])
            await AppTestSupport.waitUntil(timeout: .seconds(3)) { viewModel.isAudioReady }
            #expect(viewModel.isAudioReady == true)
            await AppTestSupport.waitUntil(timeout: .seconds(2)) { viewModel.localInputObservedAt != nil }
            #expect(viewModel.localInputObservedAt != nil,
                "The real native capture callback must survive call graph startup")
            if let first = viewModel.localInputObservedAt {
                try await Task.sleep(for: .milliseconds(200))
                #expect((viewModel.localInputObservedAt ?? 0) > first)
            }
            #expect(viewModel.audioPipeline.transmitEncodingFailureCount == 0)
            viewModel.disconnect()
            _ = await viewModel.audioSessionManager.requestActive(false).value
        }
    }
    #endif

    @Test func transmitFailureCannotBecomeSuccessfulSilenceAndMutedRecordingCanRestart() async {
        let harness = AppTestSupport.makeHarness(groups: []), viewModel = harness.viewModel
        viewModel.setSoundIsolationEnabled(false)
        defer { viewModel.cancelAudioCheck() }
        func emitFiveSeconds(start: Double) {
            for index in 0..<250 {
                harness.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: .intercomMixer,
                    capturedAt: start + Double(index) * 0.02, samples: [Float](repeating: 0.2, count: 960)))
            }
        }
        viewModel.startAudioCheck()
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        let before = viewModel.audioPipeline.transmitEncodingFailureCount
        viewModel.audioPipeline.processMicrophoneFrame(
            .init(
                sequenceNumber: 0, format: .init(sampleRate: 48_000, channelCount: 2),
            capturedAt: 0, samples: [Float](repeating: 0.8, count: 9601)), level: 1)
        #expect(viewModel.audioPipeline.transmitEncodingFailureCount > before)
        emitFiveSeconds(start: 10)
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
            viewModel.audioCheckPhase == .playing || viewModel.audioCheckPhase == .failed
        }
        #expect(viewModel.audioCheckPhase == .failed,
            "A swallowed transmit processing failure must invalidate this recording")
        viewModel.cancelAudioCheck()
        viewModel.applyLocalMute(true)
        viewModel.startAudioCheck()
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        emitFiveSeconds(start: 20)
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
            viewModel.audioCheckPhase == .playing || viewModel.audioCheckPhase == .failed
        }
        #expect(viewModel.audioCheckPhase == .playing, "An intentional transmit mute is a valid silent recording")
        #expect(viewModel.audioCheckRecordedFrameCount == 240_000)
        #expect(viewModel.audioCheckOutputLevel == 0)
    }

    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
    @Test func recordingObservationAlignsSparseSpeechAndMeasuresSilentIntervals() {
        func measure(_ input: [Float], _ output: [Float]) -> [String: Any] {
            var observation = AudioCheckValidationObservation(generation: UUID())
            observation.setInput([.init(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: input)])
            observation.appendOutput(.init(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: output))
            return observation.record(phase: "Audio Check Complete", status: .init(
                droppedRenderFrames: 0, droppedInputFrames: 0, inputStopped: true, outputStopped: true,
                nativeBackends: true, watchRoute: false, engineRunning: false))
        }
        let input = (0..<240_000).map { sample -> Float in
            guard (48_000..<96_000).contains(sample) || (192_000..<201_600).contains(sample) else { return 0 }
            return Float(0.2 * sin(Double(sample) * Double(sample) * 0.000_019))
        }
        let output = [Float](repeating: 0, count: 1440) + input + [Float](repeating: 0, count: 480)
        let report = measure(input, output)
        #expect(report["comparison"] as? String == "measured")
        #expect(report["fullCoverage"] as? Bool == true)
        #expect(abs((report["lagSeconds"] as? Double ?? -1) - 0.03) < 1 / 48_000)
        #expect((report["fullSignalCorrelation"] as? Double ?? -1) > 0.9999)
        #expect((report["silentResidualRMS"] as? Double ?? 1) < 0.00001)
        var corrupt = output
        for index in 131_040..<135_840 { corrupt[index] = 0.1 }
        #expect((measure(input, corrupt)["silentResidualRMS"] as? Double ?? 0) > 0.001)
        let silent = measure([Float](repeating: 0, count: 240_000), [Float](repeating: 0, count: 241_920))
        #expect(silent["comparison"] as? String == "unidentifiable")
        #expect(silent["lagSeconds"] == nil)
    }
    #endif
}
