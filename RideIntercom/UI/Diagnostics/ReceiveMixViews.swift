import SwiftUI
import AudioCore
import AudioMixer
import RTC
import SessionManager

struct ReceiveOutputMixGroup: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let step: PipelineStep
    let effectStep: PipelineStep
    let effectStages: [EffectChainStage]
    let outputMix: ReceiveOutputMixSnapshot

    private var summaryLayout: AnyLayout {
        if dynamicTypeSize.isAccessibilitySize {
            AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.small))
        } else {
            AnyLayout(HStackLayout(alignment: .top, spacing: AppSpacing.small))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.extraSmall) {
            CompactPipelineStepRow(step: step, accessibilityIdentifier: "\(step.accessibilityIdentifier)-summary")

            summaryLayout {
                HStack(alignment: .top, spacing: AppSpacing.small) {
                    Circle()
                        .fill(outputMix.state.color)
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AppSpacing.extraExtraSmall) {
                        Text("\(outputMix.sourceBusCount) buses / RX \(outputMix.receivedFrameCount)")
                            .font(AppTypography.caption2Mono)
                            .foregroundStyle(AppColorPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(
                            outputMix.isMuted
                                ? "OUT muted"
                                : "VOL \(Int(outputMix.outputVolume * 100))% / FX \(outputMix.effectSummary)"
                        )
                            .font(AppTypography.caption2Mono)
                            .foregroundStyle(AppColorPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VoiceMeterView(
                    level: outputMix.isMuted ? 0 : outputMix.outputLevel,
                    peakLevel: outputMix.isMuted ? 0 : outputMix.outputPeakLevel,
                    isMuted: outputMix.isMuted,
                    showsValueText: false
                )
                .frame(width: 72)
            }
            .padding(.horizontal, AppSpacing.small)
            .padding(.vertical, AppSpacing.extraSmall)
            .background(AppColorPalette.panelSurface)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.card))
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : CompactPipelineLayout.childIndent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Receive mix down to master")
            .accessibilityValue("\(outputMix.sourceBusCount) peer buses, received \(outputMix.receivedFrameCount)")
            .accessibilityIdentifier("receive-master-mix-card")

            CompactEffectChainGroup(
                step: effectStep,
                title: "RX Master Effects",
                accessibilityIdentifier: "receive-pipeline-master-effects-step",
                stageIdentifierPrefix: "receive-master-effect-stage",
                stages: effectStages
            )
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : CompactPipelineLayout.childIndent)
        }
        .padding(.vertical, AppSpacing.extraSmall)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(step.accessibilityIdentifier)
    }
}
