import SwiftUI
import AudioCore
import SessionManager

struct LiveReceivePipelineView: View {
    @Bindable var viewModel: IntercomViewModel
    @Binding var expandedStage: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let input = DiagnosticsInput(viewModel, now: context.date.timeIntervalSince1970)
            pipeline(ReceivePipelinePresentation(input: input))
        }
    }

    private func pipeline(_ presentation: ReceivePipelinePresentation) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            CompactPipelineHeader(title: "Live RX Pipeline", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath", detail: "Peers -> mix -> RX master -> output")
            CompactPipelineStepRow(step: presentation.rtcReceiveStep)
                .id("receive-input")
            CompactPipelineStepRow(step: presentation.codecDecodeStep)
            CompactPipelineStepRow(step: presentation.peerBusStep)
            DiagnosticsReceiveDetails(presentation: presentation, expandedStage: $expandedStage)
                .id("receive-peers")
            ReceiveMasterMixGroup(step: presentation.masterBusStep, effectStep: presentation.masterEffectChainStep, effectStages: presentation.masterEffectStages, master: presentation.receiveMasterMix)
            DisclosureGroup(isExpanded: Binding(get: { expandedStage == "receive-output" }, set: { expandedStage = $0 ? "receive-output" : nil })) {
                let input = presentation.input
                let stream = input.lastOutputStreamOperationReport?.snapshot
                Text("Device: \(input.audioSessionSnapshot.currentOutput.name)")
                if let format = stream?.actualHardwareFormat {
                    Text("Format: \(Int(format.sampleRate)) Hz / \(format.channelCount) channels")
                }
                Text("Buffered: \(stream?.bufferedOutputDuration.map { String(format: "%.0f ms", $0 * 1000) } ?? "Not measured") / Resets: \(stream?.playbackResetCount.map(String.init) ?? "Not measured")")
            } label: { CompactPipelineStepRow(step: presentation.outputStep) }
                .id("receive-output")
        }
        .appDiagnosticsCardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveReceivePipelineView")
    }
}
