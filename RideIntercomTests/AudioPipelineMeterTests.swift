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

#if os(iOS)
    import SwiftUI
#endif

extension AppTests.AudioPipelineTests {
    @Test func nativeOutputMeterKeepsRenderedSpeechWithoutPCMDelivery() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        let model = AppTestSupport.makeHarness(audioPipeline: pipeline).viewModel
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        model.isAudioReady = true
        pipeline.onOutputFrame = nil
        let frame = PCMFrame(sequenceNumber: 0, format: .intercomMixer, samples: Array(repeating: 0.2, count: 9600))
        _ = try pipeline.processReceivedAudioPacket(
            AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16))
        func renderAndObserve() throws {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            for _ in 0..<44 {
                #expect(try engine.renderOffline(480, to: buffer) == .success)
                Thread.sleep(forTimeInterval: 0.002)
            }
            model.handleCallTick(now: Date().timeIntervalSince1970)
        }
        // The MainActor has not serviced any per-frame callback or timer yet.
        try renderAndObserve()
        let first = try #require(pipeline.lastNativeAudibleOutputAt)
        #expect(model.nativeRenderedOutputBatchCount > 0)
        #expect(model.scheduledOutputBatchCount == 0)
        let output = ReceivePipelinePresentation(input: DiagnosticsInput(model)).outputStep
        #expect(output.state == .passing)
        #expect(output.detail.hasPrefix("Last audible PCM"))
        #expect(model.diagnosticsOutputPeakLevel > 0.1)
        #expect(
            model.diagnosticsOutputLevel == 0,
            "Late meter refresh must show the current silence as well as the recent peak")
        let stale = ReceivePipelinePresentation(input: DiagnosticsInput(model, now: first + 3)).outputStep
        #expect(stale.state == .waiting)
        #expect(stale.detail.hasPrefix("Last audible PCM · 3s ago / Last render"))

        let resumed = PCMFrame(sequenceNumber: 1, format: frame.format, samples: frame.samples)
        _ = try pipeline.processReceivedAudioPacket(
            AppTestSupport.receivedAudioPacket(peerID: "peer", frame: resumed, codec: .pcm16))
        try renderAndObserve()
        #expect((pipeline.lastNativeAudibleOutputAt ?? 0) > first)
        #expect(ReceivePipelinePresentation(input: DiagnosticsInput(model)).outputStep.state == .passing)
        #if os(iOS)
            model.audioMixerSnapshot = pipeline.snapshot
            try attachReceiveOutput(model: model, name: "rendered")
        #endif
        pipeline.stop()
        let batchCount = model.nativeRenderedOutputBatchCount
        model.handleCallTick(now: Date().timeIntervalSince1970)
        #expect(model.nativeRenderedOutputBatchCount == batchCount)
        #expect(
            ReceivePipelinePresentation(input: DiagnosticsInput(model)).outputStep.detail == "No audible PCM observed")
    }

    @Test func receiveDiagnosticsSeparateStalledRenderingFromContinuingDecoding() async throws {
        let engine = AVAudioEngine()
        let nativeFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: nativeFormat, maximumFrameCount: 480)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        let harness = AppTestSupport.makeHarness(audioPipeline: pipeline)
        harness.outputBackend.rendersToHardware = true
        let model = harness.viewModel
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        defer { model.disconnect() }
        await AppTestSupport.waitUntil { model.isAudioReady }
        try #require(model.isAudioReady && pipeline.rendersToHardware)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: 480))
        var sequence: UInt64 = 0

        func receive(_ value: Float, count: Int) throws {
            let frame = PCMFrame(
                sequenceNumber: sequence, format: .intercomMixer, samples: Array(repeating: value, count: count))
            sequence += 1
            harness.callSession.receive(
                try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        }

        try receive(0.2, count: 2_880)
        let firstRendered = try await renderUntil(engine: engine, buffer: buffer, pipeline: pipeline, model: model) {
            $0.contains { $0 > 0.05 }
        }
        try #require(firstRendered)
        try await Task.sleep(for: .milliseconds(40))
        model.handleCallTick(now: Date().timeIntervalSince1970)
        let first = try #require(pipeline.lastNativeAudibleOutputAt)
        let pausedAt = engine.manualRenderingSampleTime
        let firstDecodeCount = pipeline.receiveDecodeCounts.pcmPackets
        let deadline = ContinuousClock.now + .milliseconds(2_100)
        repeat {
            try receive(-0.2, count: 480)
            try await Task.sleep(for: .milliseconds(12))
        } while ContinuousClock.now < deadline

        model.handleCallTick(now: Date().timeIntervalSince1970)
        checkStalledOutput(
            engine: engine, pipeline: pipeline, stalled: diagnostics(model),
            baseline: .init(pausedAt: pausedAt, first: first, decodeCount: firstDecodeCount))
        #if os(iOS)
            try attachReceiveOutput(model: model, name: "stalled")
        #endif

        try receive(-0.2, count: 2_880)
        let resumed = try await renderUntil(
            engine: engine, buffer: buffer, pipeline: pipeline, model: model, after: first
        ) { $0.contains { $0 < -0.05 } }
        #expect(resumed)
        #expect((pipeline.lastNativeAudibleOutputAt ?? 0) > first)
        #expect(diagnostics(model).outputStep.state == .passing)
    }

    @Test func appDecodeRejectsUnknownCodecAndInvalidFormatBeforeConversion() throws {
        let valid = RTCAudioPacket(
            sequenceNumber: 0, codec: .pcm16, capturedAt: 0, sampleCount: 1, payload: Data([0, 0]))
        var unknown = valid
        unknown.codec = "unknown-codec"
        #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(unknown) }
        for format in [
            RTCAudioFormat(sampleRate: 0), RTCAudioFormat(channelCount: 0), RTCAudioFormat(sampleRate: .infinity),
            RTCAudioFormat(channelCount: 3)
        ] {
            var invalid = valid
            invalid.format = format
            #expect(throws: (any Error).self) { try AppAudioCodecBridge.decode(invalid) }
        }
        #expect(try AppAudioCodecBridge.decode(valid).samples == [0])
    }

    @Test func audioTransmissionControllerKeepsVoiceAndSilenceWithoutTransportControl() {
        var controller = AudioTransmissionController(
            vadGate: VADGate(
                configuration: VADGateConfiguration(
                    attackDuration: 0.01, releaseDuration: 0.05, updateInterval: 0.02, speechThresholdOffsetDB: 6,
                    silenceThresholdOffsetDB: 3, initialNoiseFloorDBFS: -60)), preRollLimit: 2)
        func frame(_ sequenceNumber: UInt64, _ sample: Float) -> PCMFrame {
            PCMFrame(
                sequenceNumber: sequenceNumber, format: .intercomPacketAudio,
                capturedAt: TimeInterval(sequenceNumber) * 960 / 48_000, samples: Array(repeating: sample, count: 960))
        }

        #expect(controller.process(frame: frame(1, 0), level: 0) == [.silence(frame(1, 0))])
        #expect(controller.process(frame: frame(2, 0), level: 0) == [.silence(frame(2, 0))])
        #expect(controller.process(frame: frame(3, 0), level: 0) == [.silence(frame(3, 0))])

        let voicePackets = controller.process(frame: frame(4, 0.3), level: 0.3)
        #expect(voicePackets == [.voice(frame(4, 0.3))])
        #expect(controller.process(frame: frame(5, 0.3), level: 0.3) == [.voice(frame(5, 0.3))])
    }

    @Test func viewModelConnectsAuthenticatedPeerAndStartsPackageAudioPipeline() async throws {
        let harness = AppTestSupport.makeHarness()
        let group = IntercomSeedData.recentGroups[0]

        harness.viewModel.selectGroup(group)
        await AppTestSupport.waitUntil { harness.callSession.connectedGroup?.id == group.id }
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }

        #expect(harness.callSession.startMediaCallCount == 1)
        #expect(harness.audioSessionBackend.activeValues.contains(true))
        #expect(harness.inputBackend.startCount == 1)
        #expect(harness.outputBackend.startCount == 1)
        #expect(harness.viewModel.connectionState == .localConnected)
    }

    @Test func viewModelSendsVoiceSamplesFromPackageInputFrames() async throws {
        let harness = AppTestSupport.makeHarness()
        let hardwareFormat = AudioFormat(sampleRate: 44_100, channelCount: 2)

        harness.viewModel.setRTCAudioFormatPreset(.mono24k)
        harness.viewModel.setPreferredTransmitCodec(.pcm16)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        for sequenceNumber in 1...8 {
            harness.inputBackend.emit(
                PCMFrame(
                    sequenceNumber: UInt64(sequenceNumber), format: hardwareFormat,
                    capturedAt: TimeInterval(100 + sequenceNumber),
                    samples: Array(repeating: [Float(0.7), Float(0.8)], count: 2_048).flatMap { $0 }))
        }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { harness.callSession.sentAudioPackets.isEmpty == false }

        let packet = try #require(harness.callSession.sentAudioPackets.first)
        let decoded = try AppAudioCodecBridge.decode(packet)
        #expect(packet.format == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
        #expect(decoded.format == RTCAudioFormatPreset.mono24k.audioFormat)
        #expect(
            harness.callSession.audioPolicies.last?.preferredSendFormat
                == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono24k.audioFormat))
    }

    @Test func viewModelReceivesRTCFrameAndSchedulesPackageOutput() async throws {
        let harness = AppTestSupport.makeHarness()
        let group = IntercomSeedData.recentGroups[0]
        let frame = PCMFrame(
            sequenceNumber: 7, format: .intercomPacketAudio, capturedAt: 100,
            samples: Array(repeating: Float(0.2), count: 480) + Array(repeating: Float(-0.2), count: 480))

        harness.viewModel.selectGroup(group)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.callSession.receive(
            try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        await AppTestSupport.waitUntil(timeout: .seconds(5)) {
            harness.outputBackend.scheduledFrames.flatMap(\.samples).contains { abs($0 + 0.2) < 0.001 }
        }

        let remoteMember = try #require(harness.viewModel.selectedGroup?.members.first { $0.id == "member-108" })
        let scheduledFrames = harness.outputBackend.scheduledFrames
        #expect(!scheduledFrames.isEmpty)
        #expect(remoteMember.isTalking)
        #expect(remoteMember.receivedAudioPacketCount == 1)
        #expect(remoteMember.playedAudioFrameCount == 1)
        #expect(harness.viewModel.scheduledOutputBatchCount == scheduledFrames.count)
        #expect(harness.viewModel.nativeRenderedOutputBatchCount == 0)
        let output = ReceivePipelinePresentation(input: DiagnosticsInput(harness.viewModel)).outputStep
        #expect(output.state == .waiting)
        #expect(output.detail.contains("Render not measured"))
        #expect(scheduledFrames.allSatisfy { $0.format == .intercomHardwarePreferred && $0.frameCount <= 960 })
        #expect(scheduledFrames.flatMap(\.samples).contains { abs($0 - 0.2) < 0.001 })
        #expect(scheduledFrames.flatMap(\.samples).contains { abs($0 + 0.2) < 0.001 })
    }

    @Test func silentClockFramesDoNotKeepRemoteTalkingStateAlive() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(harness.viewModel.groups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let frame = PCMFrame(
            sequenceNumber: 1, format: .intercomPacketAudio, capturedAt: 0, samples: Array(repeating: 0, count: 480))
        harness.callSession.receive(
            try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        #expect(harness.viewModel.remoteVoiceReceivedAt["member-108"] == nil)
        #expect(harness.viewModel.selectedGroup?.members.first { $0.id == "member-108" }?.isTalking == false)
        #expect(harness.viewModel.receivedVoicePacketCount == 1)
        harness.viewModel.disconnect()
    }

    #if os(iOS)
        private func attachReceiveOutput(model: IntercomViewModel, name: String) throws {
            let view = LiveReceivePipelineView(viewModel: model, expandedStage: .constant("receive-output"))
                .frame(width: 370).padding().background(AppColorPalette.listScreenBackground)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            Attachment.record(try #require(renderer.uiImage?.pngData()), named: "rx-output-\(name).png")
        }
    #endif

    private func renderUntil(
        engine: AVAudioEngine, buffer: AVAudioPCMBuffer, pipeline: AppAudioPipeline, model: IntercomViewModel,
        after previous: TimeInterval = 0, _ containsMarker: ([Float]) -> Bool
    ) async throws -> Bool {
            var markerRendered = false
            for _ in 0..<60 {
                try #require(try engine.renderOffline(480, to: buffer) == .success)
                let samples = Array(
                    UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(buffer.frameLength)))
                try await Task.sleep(for: .milliseconds(3))
                model.handleCallTick(now: Date().timeIntervalSince1970)
                markerRendered = markerRendered || containsMarker(samples)
                if markerRendered, (pipeline.lastNativeAudibleOutputAt ?? 0) > previous,
                    model.diagnosticsOutputLevel > 0.05 {
                    return true
                }
            }
            return false
    }

    private struct StalledBaseline {
        let pausedAt: AVAudioFramePosition
        let first: TimeInterval
        let decodeCount: Int
    }

    private func checkStalledOutput(
        engine: AVAudioEngine, pipeline: AppAudioPipeline, stalled: ReceivePipelinePresentation,
        baseline: StalledBaseline
    ) {
        #expect(engine.manualRenderingSampleTime == baseline.pausedAt)
        #expect(pipeline.lastNativeAudibleOutputAt == baseline.first)
        #expect(pipeline.receiveDecodeCounts.pcmPackets > baseline.decodeCount + 1)
        #expect(stalled.rtcReceiveStep.state == .passing)
        #expect(stalled.codecDecodeStep.state == .passing)
        #expect(stalled.outputStep.state == .waiting)
        #expect(stalled.outputStep.detail.contains("Last render"))
        #expect(stalled.receiveOutputMix.outputLevel == 0)
        #expect(stalled.receiveOutputMix.outputPeakLevel == 0)
    }

    private func diagnostics(_ model: IntercomViewModel) -> ReceivePipelinePresentation {
        model.publishRuntimePackageReports(force: true)
        return .init(input: DiagnosticsInput(model))
    }

}
