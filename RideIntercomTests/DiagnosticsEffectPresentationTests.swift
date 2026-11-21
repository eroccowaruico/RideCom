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

extension AppTests.DiagnosticsTests {
    @Test func effectChainDisplayPreservesRuntimeRegisteredOrder() {
        let runtimeChain = AudioEffectChainSnapshot(
            id: "custom",
            effects: [
                effect(
                    id: "noise-reducer",
                    typeName: "NoiseReducer",
                    index: 0,
                    state: .active,
                    labelAndDetail: ("NR", "Ready")
                ),
                effect(
                    id: "sound-isolation",
                    typeName: "SoundIsolation",
                    index: 1,
                    state: .active,
                    labelAndDetail: ("SI", "Enabled")
                ),
                effect(
                    id: "custom-tail",
                    typeName: "CustomEffect",
                    index: 2,
                    state: .bypassed,
                    labelAndDetail: ("Tail", "Bypassed")
                )
            ]
        )

        let displayStages = runtimeChain.stages.map(EffectChainStage.init(snapshot:))

        #expect(displayStages.map(\.id) == ["noise-reducer", "sound-isolation", "custom-tail"])
        #expect(runtimeChain.compactSummary == "NR, SI, Tail")
        #expect(displayStages.map(\.state) == [.passing, .passing, .idle])
    }

    private func effect(
        id: String,
        typeName: String,
        index: Int,
        state: MixerEffectState,
        labelAndDetail: (shortLabel: String, detail: String)
    ) -> MixerEffectSnapshot {
        MixerEffectSnapshot(
            id: id,
            typeName: typeName,
            index: index,
            state: state,
            parameters: [
                MixerEffectParameterSnapshot(id: "package", value: typeName),
                MixerEffectParameterSnapshot(id: "name", value: labelAndDetail.shortLabel),
                MixerEffectParameterSnapshot(id: "shortLabel", value: labelAndDetail.shortLabel),
                MixerEffectParameterSnapshot(id: "detail", value: labelAndDetail.detail),
                MixerEffectParameterSnapshot(id: "runtimeState", value: state.rawValue)
            ]
        )
    }

    @Test func effectStagesKeepTheImplementationStateWordThatTheDotMerges() {
        func stage(_ state: AudioEffectStageRuntimeState) -> EffectChainStage {
                EffectChainStage(
                    snapshot: AudioEffectStageSnapshot(
                        id: "isolation", package: "AudioMixer", name: "SoundIsolation",
                                                                shortLabel: "ISO", detail: "", state: state))
        }
        // The dot merges waiting with unavailable and bypassed with idle; the word keeps them apart.
        #expect(stage(.waiting).state == stage(.unavailable).state)
        #expect(stage(.bypassed).state == stage(.idle).state)
            #expect(
                [AudioEffectStageRuntimeState.active, .waiting, .unavailable, .bypassed, .idle].map {
                    stage($0).runtimeState
                }
                == ["active", "waiting", "unavailable", "bypassed", "idle"])
    }

    @Test func voiceIndicatorStepsIgnoreNoiseAndRoundSpeechToQuarters() {
        #expect(StandardVoiceIndicator.step(for: 0) == 0)
        #expect(StandardVoiceIndicator.step(for: 0.0005) == 0, "Below the quietest speech is silence")
        let quiet = StandardVoiceIndicator.step(for: 0.01), loud = StandardVoiceIndicator.step(for: 0.5)
        #expect(quiet >= 0.25 && quiet < loud && loud <= 1)
        #expect([quiet, loud].allSatisfy { ($0 * 4).rounded() == $0 * 4 }, "Steps, so the symbol does not flicker")
    }

    @Test func appliedDiagnosticsSummarizeCallAndInvitationInOrder() {
        let model = AppTestSupport.makeHarness().viewModel
        let group = IntercomSeedData.recentGroups[0]
        model.selectedGroup = group
        let rows = model.diagnosticsAppliedRows
        #expect(rows.map(\.id) == ["call", "invite"])
        #expect(rows.map(\.title) == ["Call", "Invite"])
        #expect(rows.first?.summary == "CALL \(model.connectionLabel)")
        let detail = "GROUP \(group.id.uuidString.prefix(8)) / MEMBERS \(group.members.count)"
        #expect(rows.map(\.detail) == [detail, detail])
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

    @Test func networkDiagnosticsKeepObservationsAndClearOnDisconnect() {
        let harness = AppTestSupport.makeHarness()
        let model = harness.viewModel
        #expect(model.networkDiagnostics == nil)
        let route = RTCRouteNetworkDiagnostics(route: .webRTC,
            statistics: .init(roundTripTime: 0.025, bufferedBytes: 128, unavailableReason: "Loss unavailable"))
        let latest = RTCNetworkDiagnostics(routes: [route])
        model.handleTransportEvent(.networkDiagnostics(latest))
        #expect(model.networkDiagnostics == latest)
        #expect(model.networkDiagnostics?.routes.first?.statistics.packetLoss == nil)
        let older = RTCNetworkDiagnostics(generatedAt: 0, routes: [route])
        model.handleTransportEvent(.networkDiagnostics(older))
        #expect(model.networkDiagnostics == older)
        model.disconnect()
        #expect(model.networkDiagnostics == nil)
    }

    @Test func verdictNamesTheFirstStoppedThenWaitingStageWithItsReason() {
        func step(_ title: String, _ state: PipelineStepState, _ detail: String = "") -> PipelineStep {
                PipelineStep(
                    id: title, package: "", title: title, detail: detail, icon: "", state: state,
                    accessibilityIdentifier: title)
        }
        #expect(PipelineVerdict(steps: [step("Session", .passing), step("Input", .passing)])
            == PipelineVerdict(steps: [step("A", .passing)]))
        #expect(PipelineVerdict(steps: [step("Session", .passing)]).text == "Passing")
        #expect(PipelineVerdict(steps: [step("Session", .passing)]).reason == nil)
            let waiting = PipelineVerdict(steps: [
                step("Session", .passing), step("VAD", .waiting, "Not speaking"), step("Codec", .idle)
            ])
        #expect(waiting.state == .waiting)
        #expect(waiting.text == "Waiting at VAD")
        #expect(waiting.reason == "Not speaking")
            let blocked = PipelineVerdict(steps: [
                step("Session", .waiting, "Joining"), step("Input", .blocked, "Audio device disconnected.")
            ])
        #expect(blocked.text == "Blocked at Input")
        #expect(blocked.reason == "Audio device disconnected.")
        #expect(PipelineVerdict(steps: [step("Output", .muted, "Muted")]).text == "Muted at Output")
        #expect(PipelineVerdict(steps: [step("Session", .idle), step("Input", .idle)]).text == "Idle")
            #expect(
                PipelineVerdict(steps: [step("Session", .passing), step("Codec", .idle, "Media Idle")]).text
                    == "Idle at Codec")
    }

}
