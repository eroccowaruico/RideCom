import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
#if os(iOS)
import SwiftUI
#endif
@testable import RideIntercom

extension AppTests {
@MainActor
struct DiagnosticsTests {
    @Test func viewModelUsesRTCMetricsForReceiveBufferDiagnostics() async {
        let harness = AppTestSupport.makeHarness()

        harness.callSession.publishMetrics(RTC.RouteMetrics(
            route: .multipeer,
            activePeerCount: 1,
            receivedAudioFrameCount: 5,
            droppedAudioFrameCount: 2,
            queuedAudioFrameCount: 3
        ))
        await AppTestSupport.waitUntil { harness.viewModel.jitterQueuedFrameCount == 3 }

        #expect(harness.viewModel.receivedVoicePacketCount == 5)
        #expect(harness.viewModel.droppedAudioPacketCount == 2)
        #expect(harness.viewModel.jitterQueuedFrameCount == 3)
    }

    @Test func receiveDiagnosticsDistinguishRouteMetricsFromActualDecoding() async throws {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        defer { model.disconnect() }
        try #require(model.isAudioReady)
        func presentation() -> ReceivePipelinePresentation { .init(input: DiagnosticsInput(model)) }

        harness.callSession.publishMetrics(.init(route: .multipeer, activePeerCount: 1,
            receivedAudioFrameCount: 5, droppedAudioFrameCount: 0, queuedAudioFrameCount: 3))
        #expect(presentation().codecDecodeStep.state == .waiting)
        #expect(presentation().codecDecodeStep.detail == "No PCM observed")
        #expect(presentation().rtcReceiveStep.state == .waiting, "Cumulative route metrics have no receipt timestamp")

        let frame = PCMFrame(sequenceNumber: 0, format: .intercomMixer,
            samples: Array(repeating: 0.2, count: 480))
        let valid = try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16)
        var invalid = valid
        invalid.packet.payload = Data([0xff])
        harness.callSession.receive(invalid)
        #expect(presentation().codecDecodeStep.detail.contains("PCM 0 / Decode errors 1"))
        #expect(presentation().codecDecodeStep.detail.contains("Last error"))
        #expect(presentation().rtcReceiveStep.state == .passing)
        #expect(presentation().codecDecodeStep.state == .blocked)

        harness.callSession.receive(valid)
        harness.callSession.publishMetrics(.init(route: .multipeer, activePeerCount: 1,
            receivedAudioFrameCount: 8, droppedAudioFrameCount: 2, queuedAudioFrameCount: 0))
        #expect(presentation().codecDecodeStep.state == .passing)
        #expect(presentation().codecDecodeStep.detail.hasPrefix("PCM 1 / Last PCM"))
        #expect(presentation().rtcReceiveStep.detail.hasSuffix("DROP 2"))
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
            harness.outputBackend.scheduledFrames.contains { $0.samples.contains { $0 > 0.05 } }
        }
        try #require(harness.outputBackend.scheduledFrames.contains { $0.samples.contains { $0 > 0.05 } })
        harness.callSession.receive(invalid)
        #expect(presentation().codecDecodeStep.state == .passing, "A recent successful PCM observation remains visible")

        try await verifyDecodeFailureRecovery(harness: harness, frame: frame, invalid: invalid)
    }

    private func verifyDecodeFailureRecovery(
        harness: AppTestSupport.Harness, frame: PCMFrame, invalid: RTC.ReceivedAudioPacket
    ) async throws {
        let model = harness.viewModel
        func presentation() -> ReceivePipelinePresentation { .init(input: DiagnosticsInput(model)) }
        try await Task.sleep(for: .milliseconds(2_100))
        let beforeFailure = harness.outputBackend.scheduledFrames.count
        harness.callSession.receive(invalid)
        model.publishRuntimePackageReports(force: true)
        let failed = presentation()
        #expect(failed.rtcReceiveStep.state == .passing)
        #expect(failed.codecDecodeStep.state == .blocked)
        #expect(failed.codecDecodeStep.detail.contains("Decode errors 3 / Last error"))
        #expect(PipelineVerdict(steps: [failed.rtcReceiveStep, failed.codecDecodeStep]).text == "Blocked at Decode")
        #if os(iOS)
        let renderer = ImageRenderer(content: LiveReceivePipelineView(viewModel: model, expandedStage: .constant(nil))
            .frame(width: 370).padding().background(AppColorPalette.listScreenBackground))
        renderer.scale = 2
        Attachment.record(try #require(renderer.uiImage?.pngData()), named: "rx-decode-blocked.png")
        #endif
        try await Task.sleep(for: .milliseconds(70))
        let duringFailure = harness.outputBackend.scheduledFrames.dropFirst(beforeFailure)
        #expect(!duringFailure.isEmpty)
        #expect(duringFailure.allSatisfy { $0.samples.allSatisfy { abs($0) < 0.001 } })

        let later = DiagnosticsInput(model, now: Date().timeIntervalSince1970 + 3)
        let stale = ReceivePipelinePresentation(input: later)
        #expect(stale.rtcReceiveStep.state == .waiting)
        #expect(stale.codecDecodeStep.state == .waiting)
        let resumed = PCMFrame(sequenceNumber: 1, format: frame.format,
            samples: Array(repeating: -0.2, count: 480))
            harness.callSession.receive(
                try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: resumed, codec: .pcm16))
        await AppTestSupport.waitUntil(timeout: .seconds(3)) {
                harness.outputBackend.scheduledFrames.dropFirst(beforeFailure).contains {
                    $0.samples.contains { $0 < -0.05 }
                }
        }
            #expect(
                harness.outputBackend.scheduledFrames.dropFirst(beforeFailure).contains {
                    $0.samples.contains { $0 < -0.05 }
                })
        #expect(presentation().rtcReceiveStep.state == .passing)
        #expect(presentation().codecDecodeStep.state == .passing)
        model.disconnect()
        #expect(model.audioPipeline.receiveDecodeCounts == .init())
        #expect(presentation().codecDecodeStep.state == .idle)
    }

    @Test func receiveMixCountsOnlyRoutedPeerBusesAndUsesTheirAudioEvidence() {
        let now: TimeInterval = 100
        var input = DiagnosticsInput(AppTestSupport.makeHarness().viewModel, now: now)
        input.isAudioReady = true
        input.authenticatedPeerCount = 3
        input.receivedVoicePacketCount = 8
        input.audioMixerSnapshot.outputBusID = "engine-output"
        input.audioMixerSnapshot.routes = [
            .init(sourceBusID: "rx-peer-first", destinationBusID: "rx-master"),
            .init(sourceBusID: "rx-peer-second", destinationBusID: "rx-master"),
            .init(sourceBusID: "rx-master", destinationBusID: "rx-output")
        ]
        func presentation() -> ReceivePipelinePresentation { .init(input: input) }

        #expect(presentation().receiveMixStep.detail == "2 routes → rx-master")
        #expect(presentation().receiveOutputMix.sourceBusCount == 2)
        #expect(presentation().receiveMixStep.state == .waiting)
        #expect(presentation().receivePeerStates["first"] == .waiting)
        #expect(presentation().receivePeerStates["third"] == nil)

        input.audioMixerSnapshot.buses = [
            .init(id: "rx-peer-first", volume: 1, sourceCount: 1, effectCount: 0,
                    sources: [
                        .init(
                            id: "pcm", typeName: "MixerPCMSource", index: 0, inputBusIndex: 0,
                            scheduledFrameCount: 1)
                    ])
        ]
        #expect(presentation().receivePeerStates["first"] == .waiting)
        input.audioMixerSnapshot.buses[0].sources[0].lastScheduledAt = now - 2.01
        #expect(presentation().receivePeerStates["first"] == .waiting)
        input.audioMixerSnapshot.buses[0].sources[0].lastScheduledAt = now - 2
        #expect(presentation().receivePeerStates["first"] == .passing)
        #expect(presentation().receivePeerStates["second"] == .waiting)
        #expect(presentation().receiveMixStep.state == .passing)

        input.audioMixerSnapshot.routes.removeFirst()
        #expect(presentation().receivePeerStates["first"] == nil)
        #expect(presentation().receiveMixStep.detail == "1 route → rx-master")
        #expect(presentation().receiveMixStep.state == .waiting)
    }

    @Test func viewModelExposesTransmitEffectChainFromRuntimeSettings() {
        let harness = AppTestSupport.makeHarness()

        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
        harness.viewModel.setSoundIsolationEnabled(false)
        #expect(!harness.viewModel.isSoundIsolationEnabled)
        #expect(harness.viewModel.transmitEffectChainSnapshot.stages.isEmpty)
    }

    @Test func transmitFlowUsesObservedVoiceActivityForVAD() {
        let model = AppTestSupport.makeHarness().viewModel
        var input = DiagnosticsInput(model)
        input.isAudioReady = true
        input.isMuted = false
        let gate = VADGate(configuration: VoiceActivitySensitivity.standard.configuration)

        _ = gate.process(rmsDBFS: -120, duration: 0.02)
        input.vadGateRuntimeSnapshot = gate.runtimeSnapshot
        var presentation = TransmitPipelinePresentation(input: input)
        #expect(presentation.flowSteps.map(\.id) == ["session", "input", "vad", "mixer", "codec", "rtc"])
        #expect(presentation.vadStep.state == .waiting)
        #expect(presentation.vadStep.detail.hasPrefix("Silence"))

        _ = gate.process(rmsDBFS: -20, duration: 0.1)
        input.vadGateRuntimeSnapshot = gate.runtimeSnapshot
        presentation = .init(input: input)
        #expect(presentation.vadStep.state == .passing)

        input.isMuted = true
        #expect(TransmitPipelinePresentation(input: input).vadStep.state == .idle)
    }

    @Test func transmitBusShowsAnUnavailableEffectInTheFlow() {
        let model = AppTestSupport.makeHarness().viewModel
        var input = DiagnosticsInput(model)
        input.isAudioReady = true
        #expect(TransmitPipelinePresentation(input: input).mixerBusStep.state == .waiting)

        input.audioMixerSnapshot.buses = [.init(id: "tx-bus", volume: 1, sourceCount: 1, effectCount: 1)]
        input.transmitEffectChainSnapshot = .init(id: "tx-bus",
            effects: [.init(id: "Isolation", typeName: "SoundIsolation", index: 0, state: .unavailable)])
        let bus = TransmitPipelinePresentation(input: input).mixerBusStep
        #expect(bus.state == .waiting)
        #expect(bus.detail.contains("Isolation unavailable"))
    }

    @Test func transmitBusShowsAppliedIsolationBeforeExpandingEffects() async throws {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        func presentation() -> TransmitPipelinePresentation { .init(input: DiagnosticsInput(model)) }

        #expect(presentation().mixerBusStep.detail == "Not available")
        model.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { model.isAudioReady }
        defer { model.disconnect() }
        try #require(model.isAudioReady)
        model.applyLocalMute(false)
        let format = AudioFormat.intercomMixer
        let speech = (0..<480).map { Float(0.1 * sin(Double($0) * 2 * .pi / 120)) }
        let silence = Array(repeating: Float.zero, count: speech.count)
        var sequence: UInt64 = 0
        func feed(_ samples: [Float], frames: Int) {
            for _ in 0..<frames {
                let frame = PCMFrame(sequenceNumber: sequence, format: format,
                    capturedAt: Double(sequence * UInt64(samples.count)) / format.sampleRate, samples: samples)
                model.audioPipeline.processMicrophoneFrame(frame)
                model.handleMicrophoneFrame(frame)
                sequence += 1
            }
        }

        for enabled in [false, true] {
            model.setSoundIsolationEnabled(enabled)
            let graphState = try #require(model.audioPipeline.isolationRuntimeSnapshots["tx-bus"])
            let expectedState = enabled ? "active" : "bypassed"
            #expect(graphState.state.rawValue == expectedState)
            let transmit = presentation()
            let effect = try #require(transmit.transmitEffectStages.first { $0.id == "sound-isolation" })
            #expect(effect.runtimeState == expectedState)
            #expect(transmit.mixerBusStep.state == .passing)
            #expect(transmit.mixerBusStep.detail.contains("Isolation \(expectedState)"))

            let before = try #require(transmit.encodedAudioPacketCount)
            feed(speech, frames: 60)
            let speaking = presentation()
            let analysis = try #require(speaking.voiceActivityAnalysis)
            #expect(speaking.vadStep.state == .passing)
            #expect(abs(analysis.rmsDBFS + 23.0) < 0.2, "VAD observes the same input RMS in either TX isolation state")
            let encoded = try #require(speaking.encodedAudioPacketCount)
            #expect(encoded > before)

            feed(silence, frames: 120)
            let quiet = presentation()
            #expect(quiet.vadStep.detail.hasPrefix("Silence"))
            #expect(quiet.vadStep.state == .waiting)
            #expect(quiet.mixerBusStep.detail.contains("Isolation \(expectedState)"))
            feed(silence, frames: 25)
            #expect(presentation().encodedAudioPacketCount == quiet.encodedAudioPacketCount)
        }
    }

}
}

extension AppTests.DiagnosticsTests {
    @Test func isolationConfigurationReportMatchesTheAppliedEffect() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        defer { harness.viewModel.disconnect() }
        for enabled in [true, false, true] {
            harness.viewModel.setSoundIsolationEnabled(enabled)
            harness.viewModel.setReceiveMasterSoundIsolationEnabled(enabled)
            let reports = harness.viewModel.makeRuntimePackageReports(generatedAt: 100)
            for (kind, bus) in [("transmitConfiguration", "tx-bus"), ("receiveMasterConfiguration", "rx-master")] {
                let report = try #require(reports.first { $0.package == "SoundIsolation" && $0.kind == kind })
                let configuration = try report.decodeJSON(VoiceIsolationConfiguration.self)
                let runtime = try #require(harness.viewModel.audioPipeline.isolationRuntimeSnapshots[bus])
                #expect(configuration == runtime.configuration)
                #expect(configuration.mix == 0.5, "Changing bypass preserves the configured mix")
                #expect(runtime.state == (enabled ? .active : .bypassed))
            }
        }
    }

    @Test func hiddenDiagnosticsAvoidsFastSnapshotsButVisibleMetersStayLive() {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        model.publishRuntimePackageReports(force: true, now: 100)
        let before = harness.callSession.runtimePackageReports.count
        model.publishRuntimePackageReports(now: 100.6)
        #expect(harness.callSession.runtimePackageReports.count == before)
        model.isDiagnosticsVisible = true
        model.publishRuntimePackageReports(now: 101.2)
        #expect(harness.callSession.runtimePackageReports.count == before + 1)
        model.isDiagnosticsVisible = false
        model.publishRuntimePackageReports(now: 106.2)
        #expect(harness.callSession.runtimePackageReports.count == before + 2)
        model.publishRuntimePackageReports(force: true, now: 106.3)
        #expect(harness.callSession.runtimePackageReports.count == before + 3, "Settings reports remain immediate")
    }

    @Test func viewModelPublishesPackageRuntimeReportsForDiagnosticsAndRTC() throws {
        let harness = AppTestSupport.makeHarness()
        let peerID = "member-108"

        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: true)
        harness.viewModel.publishRuntimePackageReports(force: true, now: 100)

        let reports = try #require(harness.callSession.runtimePackageReports.last)
        #expect(reports.map(\.package).contains("AudioMixer"))
        #expect(reports.map(\.package).contains("Codec"))
        #expect(reports.map(\.package).contains("VADGate"))
        #expect(reports.map(\.package).contains("SessionManager"))

        let mixerReport = try #require(reports.first { $0.package == "AudioMixer" && $0.kind == "snapshot" })
        let mixerSnapshot = try mixerReport.decodeJSON(AudioMixerSnapshot.self)
        #expect(mixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        #expect(mixerSnapshot.buses.isEmpty) // No authenticated media, so no active graph.
            #expect(
                !reports.contains {
                    ["SoundIsolation", "DynamicsProcessor", "PeakLimiter"].contains($0.package)
                        && $0.kind.contains("Runtime")
                })

        let codecReport = try #require(reports.first { $0.package == "Codec" && $0.kind == "runtimeReport" })
        let codecRuntime = try codecReport.decodeJSON(CodecRuntimeReport.self)
        #expect(codecRuntime.requestedConfiguration.codec.rawValue == harness.viewModel.preferredTransmitCodec.rawValue)

        let vadReport = try #require(reports.first { $0.package == "VADGate" && $0.kind == "runtimeSnapshot" })
        let vadRuntime = try vadReport.decodeJSON(VADGateRuntimeSnapshot.self)
        #expect(vadRuntime.configuration == harness.viewModel.vadSensitivity.configuration)
    }

}
