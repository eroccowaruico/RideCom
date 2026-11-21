import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import Synchronization
import Testing
import VADGate

@testable import RideIntercom

extension AppTests.AudioPipelineTests {
    @Test func viewModelBroadcastsMuteStateAndUpdatesPackageVoiceProcessing() async throws {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.toggleMute()

        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.inputMuted == true)
        #expect(harness.inputBackend.voiceProcessingConfigurations.last?.soundIsolationEnabled == false)
        #expect(harness.callSession.localMuteValues.last == true)
        #expect(harness.callSession.sentControlMessages.contains(.peerMuteState(isMuted: true)))
        #expect(harness.callSession.sentControlMessages.contains(.keepalive))
    }

    @Test func viewModelAudioCheckRecordsAndSchedulesPlaybackThroughPackageOutput() async {
        let harness = AppTestSupport.makeHarness(groups: [])
        harness.viewModel.setSoundIsolationEnabled(false)

        harness.viewModel.startAudioCheck(recordDuration: .seconds(5), playbackDuration: .seconds(5))
        await AppTestSupport.waitUntil { harness.viewModel.audioCheckPhase == .recording }
        harness.inputBackend.emit(
            PCMFrame(
                sequenceNumber: 1, format: AudioFormat(sampleRate: 44_100, channelCount: 2), capturedAt: 100,
                samples: Array(repeating: 0.5, count: 1764)))
        await AppTestSupport.waitUntil { harness.viewModel.audioCheckInputLevel > 0 }
        harness.viewModel.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(harness.outputBackend.configurations.last?.maximumBufferedDuration == 0.1)

        #expect(harness.viewModel.audioCheckPhase == .playing)
        #expect(harness.viewModel.audioCheckInputLevel > 0)
        #expect(harness.viewModel.audioCheckOutputLevel > 0)
        await AppTestSupport.waitUntil { !harness.outputBackend.scheduledFrames.isEmpty }
        #expect(!harness.outputBackend.scheduledFrames.isEmpty)
        if let scheduledFrame = harness.outputBackend.scheduledFrames.first {
            #expect(
                scheduledFrame.samples.contains { abs($0) > 0.01 },
                "Playback contains the actual transmit DSP output, whose gain can differ from raw input")
            #expect(scheduledFrame.format == .intercomHardwarePreferred)
        } else {
            Issue.record("Expected one audio check playback frame")
        }
    }

    @Test func viewModelKeepsParticipantOutputVolumeInsideAppAudioPipeline() async {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate([peerID])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let policiesBefore = harness.callSession.audioPolicies
        harness.viewModel.setRemoteOutputVolume(peerID: peerID, volume: 0.25)
        let peerSource = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-\(peerID)" }?.sources
            .first { $0.id == "rtc-audio-\(peerID)" }

        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == 0.25)
        #expect(harness.callSession.audioPolicies == policiesBefore)
        #expect(peerSource?.id == "rtc-audio-\(peerID)")
    }

    @Test func viewModelTracksReceiveVoiceIsolationControls() {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        #expect(!harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(!harness.viewModel.receiveMixSoundIsolationEnabled)
        #expect(harness.viewModel.supportsSoundIsolation == VoiceIsolationSupport.isAvailable)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMixEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.receiveMixEffectChainSnapshot.stages.isEmpty)

        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.setReceiveMixSoundIsolationEnabled(true)

        #expect(harness.viewModel.isRemoteSoundIsolationEnabled(peerID: peerID))
        #expect(harness.viewModel.receiveMixSoundIsolationEnabled)
        #expect(harness.viewModel.receivePeerEffectChainSnapshot(peerID: peerID).stages.isEmpty)
        #expect(harness.viewModel.receiveMixEffectChainSnapshot.stages.isEmpty)
        #expect(harness.viewModel.remoteOutputVolume(for: peerID) == IntercomViewModel.defaultRemoteOutputVolume)
        #expect(harness.viewModel.overallOutputVolume == IntercomViewModel.defaultOverallOutputVolume)
    }

    @Test func viewModelTracksRemoteCodecMetadataPerPeer() throws {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: [peerID]))
        harness.viewModel.handleTransportEvent(
            .authenticated(members: [
                .init(
                    peer: .init(id: .init(rawValue: peerID), displayName: "Rider"), route: .multipeer,
                    isConnected: true, membershipID: UUID())
            ]))
        harness.viewModel.handleTransportEvent(.remotePeerMetadata(peerID: peerID, activeCodec: .opus))

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == peerID })
        #expect(remoteMember.connectionState == .connected)
        #expect(remoteMember.authenticationState == .authenticated)
        #expect(remoteMember.activeCodec == .opus)
    }

    @Test(arguments: [true, false]) func partialAudioStartCleansUpAndRetries(inputFails: Bool) async throws {
        let harness = AppTestSupport.makeHarness()
        if inputFails {
            harness.inputBackend.startError = AudioStreamError.engineOperationFailed("input")
        } else {
            harness.outputBackend.startError = AudioStreamError.engineOperationFailed("output")
        }
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        let deadline = harness.viewModel.callDisconnectDeadline
        #expect(deadline != nil)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.audioErrorMessage != nil }
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == 1)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        // Audio resources stop, while the waiting call must still expire.
        #expect((try #require(harness.viewModel.callTicker as? NoOpCallTicker)).isRunning)
        #expect(harness.viewModel.callDisconnectDeadline == deadline)
        harness.inputBackend.startError = nil
        harness.outputBackend.startError = nil
        harness.viewModel.startActiveCallAfterAuthenticatedPeer()
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.callDisconnectDeadline == deadline)
        harness.viewModel.disconnect()
        #expect(!(try #require(harness.viewModel.callTicker as? NoOpCallTicker)).isRunning)
    }

    @Test func audioCheckRetainsTheWholeFiveSecondRecordingForPlayback() async throws {
        let harness = AppTestSupport.makeHarness(groups: [])
        let viewModel = harness.viewModel
        viewModel.setSoundIsolationEnabled(false)
        viewModel.startAudioCheck()
        await AppTestSupport.waitUntil { viewModel.audioCheckPhase == .recording }
        defer { viewModel.cancelAudioCheck() }
        for index in 0..<250 {
            let frequency = index < 80 ? 440.0 : (index < 170 ? 660.0 : 997.0)
            let samples = (0..<960).map { Float(0.3 * sin(Double(index * 960 + $0) * 2 * .pi * frequency / 48_000)) }
            harness.inputBackend.emit(
                .init(
                    sequenceNumber: UInt64(index), format: .intercomMixer, capturedAt: Double(index) * 0.02,
                    samples: samples))
        }
        await AppTestSupport.waitUntil(timeout: .seconds(3)) { viewModel.audioCheckPhase == .playing }
        #expect(viewModel.audioCheckPhase == .playing)
        let expected = try #require(viewModel.audioCheckRecording).recordedFrames().flatMap(\.samples)
        #expect(expected.count == 240_000)
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
            harness.outputBackend.scheduledFrames.reduce(0) { $0 + $1.frameCount } >= 252_000
        }
        let samples = harness.outputBackend.scheduledFrames.flatMap(\.samples)
        let expectedAudible = expected.filter { abs($0) > 0.04 }.count
        #expect(expectedAudible > 0)
        #expect(
            samples.filter { abs($0) > 0.04 }.count >= expectedAudible - 960,
            "The complete actual transmit recording must survive the finite playback queue")
        #expect(viewModel.audioPipeline.droppedRenderFrameCount == 0)
        func projection(_ values: [Float], frequency: Double) -> Double {
            let sum = values.enumerated().reduce((0.0, 0.0)) { sum, item in
                let phase = Double(item.offset) * 2 * .pi * frequency / 48_000
                return (sum.0 + Double(item.element) * cos(phase), sum.1 + Double(item.element) * sin(phase))
            }
            return hypot(sum.0, sum.1)
        }
        for frequency in [440.0, 660.0, 997.0] {
            let reference = projection(expected, frequency: frequency)
            #expect(reference > 100)
            #expect(
                projection(samples, frequency: frequency) >= reference * 0.95,
                "Playback retains the actual processed beginning, middle and ending")
        }
    }

    @Test func audioCheckIsCancelledBeforeCallStartsAndCannotStopCallLater() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.startAudioCheck(recordDuration: .milliseconds(80), playbackDuration: .milliseconds(50))
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        let inputStops = harness.inputBackend.stopCount
        try? await Task.sleep(for: .milliseconds(180))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.stopCount == inputStops)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test(arguments: [RTC.RouteKind.multipeer, .webRTC]) func individualVolumeScalesRealPCMThroughEveryRoute(
        route: RTC.RouteKind
    ) async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.setRTCTransportRoute(route == .webRTC ? .multipeer : .webRTC, enabled: false)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108", "member-109"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        defer { harness.viewModel.disconnect() }
        harness.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        harness.viewModel.setRemoteOutputVolume(peerID: "member-109", volume: 0)
        harness.viewModel.setOverallOutputVolume(0.5)
        let wave = (0..<3840).map { Float(sin(Double($0) * 2 * .pi * 400 / 48000)) * 0.4 }
        let frame = PCMFrame(sequenceNumber: 1, format: .intercomMixer, capturedAt: 0, samples: wave)
        for peer in ["member-108", "member-109"] {
            harness.callSession.receive(
                try AppTestSupport.receivedAudioPacket(peerID: peer, frame: frame, codec: .pcm16))
        }
        // Render through the 200 ms playout delay and the complete 80 ms tone.
        // Silent render frames now retain time at the hardware boundary.
        await AppTestSupport.waitUntil { harness.outputBackend.scheduledFrames.flatMap(\.samples).count >= 19200 }
        let frames = harness.outputBackend.scheduledFrames.filter { $0.samples.contains { abs($0) > 0.000001 } }
        let samples = frames.flatMap(\.samples)
        #expect(samples.count >= 3072)
        let peak = samples.suffix(2048).map { abs($0) }.max() ?? 0
        // 0.4 × peer 0.25 × master 0.5; the other peer is silent.
        #expect(peak > 0.045 && peak < 0.055, "Observed peak: \(peak)")
    }

    @Test func actualOutputFollowsOverallReceiveGainAndMuteWithoutRebuilding() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"])
        defer { pipeline.stop() }
        // Give the native mixer time to ramp between gains before the tone.
        let wave =
            [Float](repeating: 0, count: 4_800)
            + (0..<9_600).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.1 }
        let payload = PCM16Codec.encode(wave)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        let settings: [OutputGainSetting] = [
            .init(volume: 1, muted: false, expectedPeak: 0.1),
            .init(volume: 0.5, muted: false, expectedPeak: 0.05),
            .init(volume: 1.5, muted: false, expectedPeak: 0.15),
            .init(volume: 1.5, muted: true, expectedPeak: 0),
            .init(volume: 1.5, muted: false, expectedPeak: 0.15)
        ]
        for (index, setting) in settings.enumerated() {
            pipeline.updateOutput(overallVolume: setting.volume, isMuted: setting.muted, peerOutputVolumes: [:])
            let packet = RTCAudioPacket(
                sequenceNumber: UInt64(index), codec: .pcm16,
                format: RTCAudioFormat(sampleRate: 48_000, channelCount: 1),
                capturedAt: Double(engine.manualRenderingSampleTime) / 48_000, sampleCount: wave.count, payload: payload
            )
            _ = try pipeline.processReceivedAudioPacket(
                ReceivedAudioPacket(peerID: PeerID(rawValue: "a"), packet: packet))
            var peak: Float = 0
            for _ in 0..<32 {
                let status = try engine.renderOffline(1024, to: buffer)
                try #require(status == .success)
                let samples = try #require(buffer.floatChannelData?[0])
                for offset in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[offset])) }
            }
            #expect(
                abs(peak - setting.expectedPeak) < 0.005,
                "Volume \(setting.volume), muted \(setting.muted), rendered peak \(peak)")
        }
    }

}

private struct OutputGainSetting {
    let volume: Float
    let muted: Bool
    let expectedPeak: Float
}
