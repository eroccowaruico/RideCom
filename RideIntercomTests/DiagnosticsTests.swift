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
        #expect(presentation().codecDecodeStep.detail == "PCM 0 / Decode errors 1")
        #expect(presentation().rtcReceiveStep.state == .passing)
        #expect(presentation().codecDecodeStep.state == .waiting)

        harness.callSession.receive(valid)
        harness.callSession.publishMetrics(.init(route: .multipeer, activePeerCount: 1,
            receivedAudioFrameCount: 8, droppedAudioFrameCount: 2, queuedAudioFrameCount: 0))
        #expect(presentation().codecDecodeStep.state == .passing)
        #expect(presentation().codecDecodeStep.detail.hasPrefix("PCM 1 / Last PCM"))
        #expect(presentation().rtcReceiveStep.detail.hasSuffix("DROP 2"))
        let later = DiagnosticsInput(model, now: Date().timeIntervalSince1970 + 3)
        let stale = ReceivePipelinePresentation(input: later)
        #expect(stale.rtcReceiveStep.state == .waiting)
        #expect(stale.codecDecodeStep.state == .waiting)
        harness.callSession.receive(valid)
        #expect(presentation().rtcReceiveStep.state == .passing)
        #expect(presentation().codecDecodeStep.state == .passing)
        model.disconnect()
        #expect(model.audioPipeline.receiveDecodeCounts == .init())
        #expect(presentation().codecDecodeStep.state == .idle)
    }

    @Test func receiveMixCountsOnlyRoutedPeerBusesAndUsesTheirAudioEvidence() {
        var input = DiagnosticsInput(AppTestSupport.makeHarness().viewModel)
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
        #expect(presentation().receiveMasterMix.sourceBusCount == 2)
        #expect(presentation().receiveMixStep.state == .waiting)
        #expect(presentation().receivePeerStates["first"] == .waiting)
        #expect(presentation().receivePeerStates["third"] == nil)

        input.audioMixerSnapshot.buses = [
            .init(id: "rx-peer-first", volume: 1, sourceCount: 1, effectCount: 0,
                sources: [.init(id: "pcm", typeName: "MixerPCMSource", index: 0, inputBusIndex: 0, scheduledFrameCount: 1)])
        ]
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
                let expectedMix: Float = bus == "tx-bus" || enabled ? 0.5 : 1
                #expect(configuration.mix == expectedMix)
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
        #expect(!reports.contains { ["SoundIsolation", "DynamicsProcessor", "PeakLimiter"].contains($0.package) && $0.kind.contains("Runtime") })

        let codecReport = try #require(reports.first { $0.package == "Codec" && $0.kind == "runtimeReport" })
        let codecRuntime = try codecReport.decodeJSON(CodecRuntimeReport.self)
        #expect(codecRuntime.requestedConfiguration.codec.rawValue == harness.viewModel.preferredTransmitCodec.rawValue)

        let vadReport = try #require(reports.first { $0.package == "VADGate" && $0.kind == "runtimeSnapshot" })
        let vadRuntime = try vadReport.decodeJSON(VADGateRuntimeSnapshot.self)
        #expect(vadRuntime.configuration == harness.viewModel.vadSensitivity.configuration)
    }

    @Test func effectChainDisplayPreservesRuntimeRegisteredOrder() {
        func effect(
            id: String,
            typeName: String,
            index: Int,
            state: MixerEffectState,
            shortLabel: String,
            detail: String
        ) -> MixerEffectSnapshot {
            MixerEffectSnapshot(
                id: id,
                typeName: typeName,
                index: index,
                state: state,
                parameters: [
                    MixerEffectParameterSnapshot(id: "package", value: typeName),
                    MixerEffectParameterSnapshot(id: "name", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "shortLabel", value: shortLabel),
                    MixerEffectParameterSnapshot(id: "detail", value: detail),
                    MixerEffectParameterSnapshot(id: "runtimeState", value: state.rawValue)
                ]
            )
        }
        let runtimeChain = AudioEffectChainSnapshot(
            id: "custom",
            effects: [
                effect(
                    id: "noise-reducer",
                    typeName: "NoiseReducer",
                    index: 0,
                    state: .active,
                    shortLabel: "NR",
                    detail: "Ready"
                ),
                effect(
                    id: "sound-isolation",
                    typeName: "SoundIsolation",
                    index: 1,
                    state: .active,
                    shortLabel: "SI",
                    detail: "Enabled"
                ),
                effect(
                    id: "custom-tail",
                    typeName: "CustomEffect",
                    index: 2,
                    state: .bypassed,
                    shortLabel: "Tail",
                    detail: "Bypassed"
                )
            ]
        )

        let displayStages = runtimeChain.stages.map(EffectChainStage.init(snapshot:))

        #expect(displayStages.map(\.id) == ["noise-reducer", "sound-isolation", "custom-tail"])
        #expect(runtimeChain.compactSummary == "NR, SI, Tail")
        #expect(displayStages.map(\.state) == [.passing, .passing, .idle])
    }

    @Test func effectStagesKeepTheImplementationStateWordThatTheDotMerges() {
        func stage(_ state: AudioEffectStageRuntimeState) -> EffectChainStage {
            EffectChainStage(snapshot: AudioEffectStageSnapshot(id: "isolation", package: "AudioMixer", name: "SoundIsolation",
                                                                shortLabel: "ISO", detail: "", state: state))
        }
        // The dot merges waiting with unavailable and bypassed with idle; the word keeps them apart.
        #expect(stage(.waiting).state == stage(.unavailable).state)
        #expect(stage(.bypassed).state == stage(.idle).state)
        #expect([AudioEffectStageRuntimeState.active, .waiting, .unavailable, .bypassed, .idle].map { stage($0).runtimeState }
                == ["active", "waiting", "unavailable", "bypassed", "idle"])
    }

    @Test func voiceIndicatorStepsIgnoreNoiseAndRoundSpeechToQuarters() {
        #expect(StandardVoiceIndicator.step(for: 0) == 0)
        #expect(StandardVoiceIndicator.step(for: 0.0005) == 0, "Below the quietest speech is silence")
        let quiet = StandardVoiceIndicator.step(for: 0.01), loud = StandardVoiceIndicator.step(for: 0.5)
        #expect(quiet >= 0.25 && quiet < loud && loud <= 1)
        #expect([quiet, loud].allSatisfy { ($0 * 4).rounded() == $0 * 4 }, "Steps, so the symbol does not flicker")
    }

    @Test func diagnosticsRowsSummarizeCurrentAppState() {
        let harness = AppTestSupport.makeHarness()
        let overviewRows = harness.viewModel.diagnosticsOverviewRows
        #expect(overviewRows.map(\.id) == ["media", "call", "network", "invite"])
        #expect(overviewRows.map(\.title) == ["Audio Path", "Call", "Network Quality", "Invite"])
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioSessionSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioInputProcessingSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "playbackDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "codecDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "audioDebugSummaryLabel" } == false)
        #expect(overviewRows.contains { $0.accessibilityIdentifier == "authenticationDebugSummaryLabel" } == false)
    }

    @Test func diagnosticsReportOnlyTheGraphActuallyProcessingAudio() async {
        let harness = AppTestSupport.makeHarness()
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.publishRuntimePackageReports(force: true)
        #expect(harness.viewModel.audioMixerSnapshot == harness.viewModel.audioPipeline.snapshot)
        harness.viewModel.disconnect()
    }

    @Test func networkDiagnosticsDistinguishUnknownValuesAndClearOnDisconnect() {
        let h = AppTestSupport.makeHarness()
        let model = h.viewModel
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
        let route = RTCRouteNetworkDiagnostics(route: .webRTC,
            statistics: .init(roundTripTime: 0.025, bufferedBytes: 128, unavailableReason: "Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("25 ms"))
        #expect(model.networkDiagnosticsSummary.contains("128 B"))
        #expect(model.networkDiagnosticsSummary.contains("Loss unavailable"))
        model.handleTransportEvent(.networkDiagnostics(.init(generatedAt: 0, routes: [route])))
        #expect(model.networkDiagnosticsSummary.contains("stale"))
        model.disconnect()
        #expect(model.networkDiagnosticsSummary.contains("Not measured"))
    }


    @Test func verdictNamesTheFirstStoppedThenWaitingStageWithItsReason() {
        func step(_ title: String, _ state: PipelineStepState, _ detail: String = "") -> PipelineStep {
            PipelineStep(id: title, package: "", title: title, detail: detail, icon: "", state: state, accessibilityIdentifier: title)
        }
        #expect(PipelineVerdict(steps: [step("Session", .passing), step("Input", .passing)])
            == PipelineVerdict(steps: [step("A", .passing)]))
        #expect(PipelineVerdict(steps: [step("Session", .passing)]).text == "Passing")
        #expect(PipelineVerdict(steps: [step("Session", .passing)]).reason == nil)
        let waiting = PipelineVerdict(steps: [step("Session", .passing), step("VAD", .waiting, "Not speaking"), step("Codec", .idle)])
        #expect(waiting.state == .waiting)
        #expect(waiting.text == "Waiting at VAD")
        #expect(waiting.reason == "Not speaking")
        let blocked = PipelineVerdict(steps: [step("Session", .waiting, "Joining"), step("Input", .blocked, "Audio device disconnected.")])
        #expect(blocked.text == "Blocked at Input")
        #expect(blocked.reason == "Audio device disconnected.")
        #expect(PipelineVerdict(steps: [step("Output", .muted, "Muted")]).text == "Muted at Output")
        #expect(PipelineVerdict(steps: [step("Session", .idle), step("Input", .idle)]).text == "Idle")
        #expect(PipelineVerdict(steps: [step("Session", .passing), step("Codec", .idle, "Media Idle")]).text == "Idle at Codec")
    }

}
}
