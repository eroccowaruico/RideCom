import SwiftUI
import Codec
import AudioCore
import SessionManager
import VADGate
import RTC

struct LiveTransmitPipelineView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var expandedStage: String?

    var body: some View {
        let presentation = TransmitPipelinePresentation(input: DiagnosticsInput(viewModel))
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(title: "Live TX Pipeline", systemImage: "point.topleft.down.curvedto.point.bottomright.up", detail: "Session -> Input -> VAD -> TX bus -> Codec -> RTC")
            stage(presentation.sessionStep) {
                if let report = viewModel.lastAudioSessionConfigurationReport {
                    Text("Requested: \(String(describing: report.requestedConfiguration.mode)) / Resolved: \(String(describing: report.resolvedConfiguration.mode))")
                    Text("Unsupported: \(report.unsupportedSettings.isEmpty ? "None reported" : report.unsupportedSettings.map { String(describing: $0) }.joined(separator: ", "))")
                } else { Text("Not measured") }
            }
            stage(presentation.inputStreamStep) {
                Text("Device: \(viewModel.audioSessionSnapshot.currentInput.name) / frames/s: Not measured")
                if let snapshot = viewModel.lastInputStreamOperationReport?.snapshot {
                    Text("Hardware: \(Int(snapshot.actualHardwareFormat.sampleRate)) Hz / \(snapshot.actualHardwareFormat.channelCount) channels / frames: \(snapshot.processedFrameCount)")
                } else { Text("Hardware format: Not measured") }
            }
            stage(presentation.vadStep) {
                Text("Microphone input before TX Bus Effects.")
                    .font(.caption)
                Text(presentation.voiceActivityAnalysis.map {
                    String(format: "Input %.1f dBFS / Noise floor %.1f dBFS / Threshold %.1f dBFS / Gain %.2f",
                           $0.rmsDBFS, $0.noiseFloorDBFS, $0.speechThresholdDBFS, $0.gain)
                } ?? "Input level: Not measured")
                .font(.caption)
            }
            stage(presentation.mixerBusStep) {
                CompactEffectChainGroup(step: presentation.mixerEffectChainStep, title: "TX Bus Effects", accessibilityIdentifier: "pipeline-effects-step", stageIdentifierPrefix: "pipeline-effect-stage", stages: presentation.transmitEffectStages)
            }
            stage(presentation.codecStep) {
                let report = viewModel.codecRuntimeReport
                Text("Requested: \(report.requestedConfiguration.codec.rawValue) / Applied: \(report.activeConfiguration.codec.rawValue) / \(Int(report.activeConfiguration.format.sampleRate)) Hz / \(report.activeConfiguration.activeBitRate.map(String.init) ?? "Not measured") bps")
                if let count = presentation.encodedAudioPacketCount {
                    Text("Encoded audio packets: \(count)")
                } else {
                    Text("Encoded audio packets: Not measured")
                }
            }
            stage(presentation.rtcStep) {
                DiagnosticsTransmitRoutes(presentation: presentation)
            }
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTransmitPipelineView")
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expandedStage == id }, set: { expandedStage = $0 ? id : nil })
    }

    private func stage<Content: View>(_ step: PipelineStep, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(isExpanded: expanded(step.id)) { content().font(.caption) } label: {
            CompactPipelineStepRow(step: step)
        }.id(step.id)
    }
}
