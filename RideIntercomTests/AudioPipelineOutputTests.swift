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
    @Test func receivePlayoutDiagnosticsKeepsTheAdjustmentWithItsPeer() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        let model = AppTestSupport.makeHarness(localMemberID: "local", audioPipeline: pipeline).viewModel
        try pipeline.rebuild(
            configuration: .init(receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["a", "b"])
        defer { pipeline.stop() }
        model.isAudioReady = true
        model.selectedGroup = try IntercomGroup(
            name: "RX playout",
            members: [
                GroupMember(id: "local", displayName: "Local"),
                GroupMember(
                    id: "a", displayName: "Haruka", authenticationState: .authenticated, connectionState: .connected),
                GroupMember(
                    id: "b", displayName: "Kenta", authenticationState: .authenticated, connectionState: .connected),
                GroupMember(
                    id: "c", displayName: "Mika", authenticationState: .authenticated, connectionState: .connected)
            ])

        let payload = PCM16Codec.encode(Array(repeating: Float(0.2), count: 480))
        func receive(_ peer: String, sequence: UInt64, capturedAt: TimeInterval) throws {
            let packet = RTCAudioPacket(
                sequenceNumber: sequence, codec: .pcm16, format: RTCAudioFormat(sampleRate: 48_000, channelCount: 1),
                capturedAt: capturedAt, sampleCount: 480, payload: payload)
            _ = try pipeline.processReceivedAudioPacket(.init(peerID: PeerID(rawValue: peer), packet: packet))
        }
        try receive("a", sequence: 0, capturedAt: 1_000)
        try receive("b", sequence: 0, capturedAt: 1_000)
        for _ in 0..<30 { try #require(engine.renderOffline(480, to: buffer) == .success) }
        try receive("a", sequence: 1, capturedAt: 1_000.36)
        model.refreshPackageRuntimeSnapshots()
        let input = DiagnosticsInput(model)
        let sourceA = try #require(input.mixerBusSnapshot(id: "rx-peer-a")?.sources.first)
        let sourceB = try #require(input.mixerBusSnapshot(id: "rx-peer-b")?.sources.first)
        #expect(sourceA.playoutAdjustmentCount == 1)
        #expect(sourceB.playoutAdjustmentCount == 0)
        #expect(sourceA.playbackResetCount == 0)
        #expect(input.mixerBusSnapshot(id: "rx-peer-c") == nil)
        let presentation = ReceivePipelinePresentation(input: input)
        #expect(presentation.playoutDetail(for: "a") == "Playout: 12 ms queued / Adjustments: 1 / Resets: 0")
        #expect(presentation.playoutDetail(for: "b") == "Playout: 0 ms queued / Adjustments: 0 / Resets: 0")
        #expect(presentation.playoutDetail(for: "c") == "Playout: Not measured")
        #expect(presentation.receiveMixStep.detail == "2 routes → rx-master")
        #if os(iOS)
            try attachPlayout(presentation: presentation)
        #endif
    }

    @Test func actualOutputLimiterProtectsCombinedPeersAfterOverallReceiveGain() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        var rendered: [Float] = []
        pipeline.onOutputFrame = { rendered += $0.samples }
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(masterOutputVolume: 2), peerIDs: ["a", "b"])
        defer { pipeline.stop() }
        let model = AppTestSupport.makeHarness().viewModel
        model.isAudioReady = true
        model.masterOutputVolume = 2
        model.authenticatedPeerIDs = ["a", "b"]
        try configureMixedGroup(model)
        func presentation() -> ReceivePipelinePresentation {
            model.audioMixerSnapshot = pipeline.snapshot
            return .init(input: DiagnosticsInput(model))
        }

        #expect(presentation().receivePeerStates == ["a": .waiting, "b": .waiting])
        #expect(presentation().receiveMixStep.detail == "2 routes → rx-master")
        #expect(presentation().outputBusStep.detail.hasPrefix("2 in /"))
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.9 }
        let packet = RTCAudioPacket(
            sequenceNumber: 0, codec: .pcm16, format: RTCAudioFormat(sampleRate: 48_000, channelCount: 1),
            capturedAt: 0, sampleCount: wave.count, payload: PCM16Codec.encode(wave))
        try receiveMixedPeers(pipeline: pipeline, packet: packet, model: model, presentation: presentation)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!rendered.isEmpty)
        #expect(rendered.allSatisfy { $0.isFinite && abs($0) <= 1.01 })
        #expect(rendered.contains { abs($0) > 0.2 })
        try await checkMixedOutput(
            pipeline: pipeline, engine: engine, packet: packet, wave: wave,
            presentation: presentation)
        #if os(iOS)
            try attachMix(model: model, name: "one-peer-resumed")
        #endif
        rendered.removeAll(keepingCapacity: true)
        for _ in 0..<12 {
            #expect(try engine.renderOffline(1024, to: buffer) == .success)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(rendered.contains { abs($0) > 0.2 })
        try pipeline.stopReceivePeer("a")
        #expect(presentation().receivePeerStates == ["b": .passing])
    }

    @Test func actualTransmitDynamicsChangesPCMBeforeEncoding() async throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        let collected = Mutex<[Float]>([])
        pipeline.onTransmitPacket = { packet in
            do {
                let samples = try AppAudioCodecBridge.decode(packet).samples
                collected.withLock { $0 += samples }
            } catch { Issue.record("Effect output could not be decoded: \(error)") }
        }
        try pipeline.rebuild(
            configuration: AppAudioPipelineConfiguration(
                rtcSendFormat: .intercomMixer, transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        let wave = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.8 }
        try pipeline.processCapturedFrame(
            PCMFrame(sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: wave))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        for _ in 0..<60 {
            _ = try engine.renderOffline(1024, to: buffer)
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))
        let rendered = collected.withLock { $0 }
        #expect(rendered.count > 24_000)
        let steady = Array(rendered.dropFirst(12_000).prefix(24_000))
        let rms = AudioLevelMeter.rmsLevel(samples: steady)
        #expect(rms > 0.02)
        #expect(rms < 0.5)  // Input RMS is about 0.566; the real Dynamics unit compresses it.
    }

    @Test func effectGraphStartFailureReleasesNodesAndCanRetry() throws {
        let failing = FailingEffectGraphEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try failing.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let working = AVAudioEngine()
        try working.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        var first = true
        let pipeline = AppAudioPipeline(makeEngine: {
            defer { first = false }
            return first ? failing : working
        })
        #expect(throws: (any Error).self) {
            try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"])
        }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: ["a"])
        #expect(pipeline.outputLimiterRuntimeSnapshot?.state == .active)
        pipeline.stop()
        #expect(pipeline.isolationRuntimeSnapshots.isEmpty)
        #expect(pipeline.outputLimiterRuntimeSnapshot == nil)
    }

    @Test func failedMixerRebuildReleasesGraphAndAllowsRetry() throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        var invalid = AppAudioPipelineConfiguration()
        invalid.mixerFormat.sampleRate = 0
        #expect(throws: (any Error).self) { try pipeline.rebuild(configuration: invalid, peerIDs: []) }
        #expect(pipeline.snapshot.busIDs.isEmpty)
        try pipeline.rebuild(configuration: AppAudioPipelineConfiguration(), peerIDs: [])
        #expect(!pipeline.snapshot.busIDs.isEmpty)
        pipeline.stop()
    }

    @Test func codecChangesPreserveActiveMixerAndReceiveReservations() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        defer { harness.viewModel.disconnect() }
        let engines = harness.audioDriver.createdEngineCount
        let frame = PCMFrame(
            sequenceNumber: 0, format: .intercomMixer, capturedAt: 0, samples: Array(repeating: 0.1, count: 960))
        harness.callSession.receive(
            try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        for codec: AudioCodecIdentifier in [.pcm16, .opus, .mpeg4AACELDv2] {
            harness.viewModel.setPreferredTransmitCodec(codec)
            harness.viewModel.setOpusBitRate(48_000)
            harness.viewModel.setAACELDv2BitRate(48_000)
            #expect(
                harness.audioDriver.createdEngineCount == engines,
                "Packet encoding changes must not reset render clocks")
            let receivedSource = try #require(
                harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-member-108" }?.sources.first)
            #expect(
                receivedSource.scheduledFrameCount == 1, "Changing transmit codec must retain already received audio")
            let expected = AppAudioCodecBridge.selectedRTCCodec(
                codec, options: .init(aacELDv2BitRate: 48_000, opusBitRate: 48_000))
            #expect(harness.viewModel.audioPipeline.audioPolicy.preferredCodecs.first == expected)
            #expect(harness.callSession.audioPolicies.last?.preferredCodecs.first == expected)
        }
    }

    #if os(iOS)
        private func attachPlayout(presentation: ReceivePipelinePresentation) throws {
            for size: DynamicTypeSize in [.large, .accessibility5] {
                let expandedStage = size == .large ? "receive-peers" : "a"
                let view = DiagnosticsReceiveDetails(
                    presentation: presentation, expandedStage: .constant(expandedStage)
                ).frame(width: 320).padding().background(AppColorPalette.listScreenBackground).environment(
                    \.dynamicTypeSize, size)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let data = try #require(renderer.uiImage?.pngData())
                Attachment.record(
                    data, named: size == .large ? "rx-playout-standard.png" : "rx-playout-accessibility.png")
            }
        }

        private func attachMix(model: IntercomViewModel, name: String, size: DynamicTypeSize = .large) throws {
            let view = LiveReceivePipelineView(viewModel: model, expandedStage: .constant(nil)).frame(width: 370)
                .padding().background(AppColorPalette.listScreenBackground).environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let data = try #require(renderer.uiImage?.pngData())
            Attachment.record(data, named: "rx-mix-\(name).png")
        }
    #endif

    private func checkMixedOutput(
        pipeline: AppAudioPipeline, engine: AVAudioEngine, packet: RTCAudioPacket, wave: [Float],
        presentation: () -> ReceivePipelinePresentation
    ) async throws {
        let output = try #require(pipeline.snapshot.buses.first { $0.id == "rx-output" })
        #expect(output.effectChain.last?.id == "peak-limiter")
        #expect(output.sinks.first?.id == "speaker-output")
        #expect(
            pipeline.snapshot.routes.contains { $0.sourceBusID == "rx-master" && $0.destinationBusID == "rx-output" })
        #expect(presentation().receivePeerStates == ["a": .passing, "b": .passing])
        try await Task.sleep(for: .milliseconds(2100))
        #expect(presentation().receivePeerStates == ["a": .waiting, "b": .waiting])
        #expect(presentation().receiveMixStep.state == .waiting)
        let nextPacket = RTCAudioPacket(
            sequenceNumber: 1, codec: .pcm16, format: packet.format,
            capturedAt: Double(engine.manualRenderingSampleTime) / 48_000, sampleCount: 480,
            payload: PCM16Codec.encode(Array(wave.prefix(480))))
        _ = try pipeline.processReceivedAudioPacket(
            ReceivedAudioPacket(peerID: PeerID(rawValue: "b"), packet: nextPacket))
        #expect(presentation().receivePeerStates == ["a": .waiting, "b": .passing])
        #expect(presentation().receiveMixStep.state == .passing)
    }

    private func configureMixedGroup(_ model: IntercomViewModel) throws {
        model.selectedGroup = try IntercomGroup(
            name: "RX mix",
            members: [
                GroupMember(id: "local", displayName: "Local"),
                GroupMember(
                    id: "a", displayName: "Haruka", authenticationState: .authenticated, connectionState: .connected),
                GroupMember(
                    id: "b", displayName: "Kenta", authenticationState: .authenticated, connectionState: .connected),
                GroupMember(id: "c", displayName: "Yu")
            ])
    }

    private func receiveMixedPeers(
        pipeline: AppAudioPipeline, packet: RTCAudioPacket, model: IntercomViewModel,
        presentation: () -> ReceivePipelinePresentation
    ) throws {
        for peer in ["a", "b"] {
            _ = try pipeline.processReceivedAudioPacket(
                ReceivedAudioPacket(peerID: PeerID(rawValue: peer), packet: packet))
            if peer == "a" {
                #expect(presentation().receivePeerStates == ["a": .passing, "b": .waiting])
                #if os(iOS)
                    try attachMix(model: model, name: "standard")
                    try attachMix(model: model, name: "accessibility", size: .accessibility5)
                #endif
            }
        }
    }

}
