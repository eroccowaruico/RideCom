import SwiftUI
import AudioCore
import RTC
import Codec
import VADGate
import SoundIsolation

struct DiagnosticsTransmitRoutes: View {
    let presentation: TransmitPipelinePresentation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let dispatch = presentation.outboundRoutes(now: context.date.timeIntervalSince1970)
            VStack(alignment: .leading, spacing: AppSpacing.extraSmall) {
                Text(dispatch.summary)
                    .foregroundStyle(.secondary)
                ForEach(dispatch.branches) { branch in
                    CompactPipelineStepRow(step: branch)
                }
                Text("Peer receipt: Not measured")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DiagnosticsReceiveDetails: View {
    let presentation: ReceivePipelinePresentation
    @Binding var expandedStage: String?

    var body: some View {
        let members = presentation.receiveParticipants
        let states = presentation.receivePeerStates
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            Text("Participants").font(.headline).accessibilityIdentifier("receive-mix-topology")
            if members.isEmpty { Text("No participants") }
            ForEach(members.filter { states[$0.id] == nil }) { member in
                participant(member, state: nil)
            }
            if states.isEmpty {
                CompactPipelineStepRow(step: presentation.receiveMixStep)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: AppSpacing.medium) {
                        ForEach(members.filter { states[$0.id] != nil }) { member in
                            branch { participant(member, state: states[member.id]) }
                        }
                    }
                    .padding(.bottom, AppSpacing.medium)
                    .overlay(alignment: .leading) {
                        connectionLine.frame(width: 1).padding(.top, AppSpacing.medium)
                    }
                    branch { CompactPipelineStepRow(step: presentation.receiveMixStep) }
                        .overlay(alignment: .topLeading) {
                            connectionLine.frame(width: 1, height: AppSpacing.medium)
                        }
                }
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("diagnosticsReceiveDetails")
    }

    private var connectionLine: some View {
        Color.accentColor.opacity(0.55)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func branch<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.leading, AppSpacing.large + AppSpacing.extraSmall)
            .overlay(alignment: .topLeading) {
                connectionLine
                    .frame(width: AppSpacing.large, height: 1)
                    .padding(.top, AppSpacing.medium)
            }
    }

    private func participant(_ member: GroupMember, state: PipelineStepState?) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedStage == member.id },
            set: { expandedStage = $0 ? member.id : nil }
        )) {
            peer(member)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.extraExtraSmall) {
                Text(member.resolvedDisplayName)
                if let state {
                    Label(state.statusText, systemImage: state.statusSymbol)
                        .foregroundStyle(state.color)
                } else {
                    Text(member.connectionState == .offline ? "Offline" : "No mixer route")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .id(member.id)
    }

    private func peer(_ member: GroupMember) -> some View {
        let detail = presentation.peerDetail(for: member.id)
        let status = detail.status
        let codecReport = detail.codec
        let vad = detail.vad
        let isolation = detail.isolation
        return VStack(alignment: .leading, spacing: AppSpacing.extraSmall) {
            if member.connectionState != .offline {
                if status?.localMute == true {
                    Label {
                        Text("Muted")
                    } icon: {
                        Image(systemName: "mic.slash.fill").foregroundStyle(AppColorPalette.danger)
                    }
                }
                Text(
                    """
                    Sender: \(status.map { $0.localMute ? "Muted" : "Unmuted" } ?? "Not measured") / codec \
                    \(codecReport.map { $0.activeConfiguration.codec.rawValue } ?? "Not measured") / bitrate \
                    \(codecReport?.activeConfiguration.activeBitRate.map { "\($0) bps" } ?? "Not measured") / \
                    VAD \(vad?.lastAnalysis.map { String(describing: $0.state) } ?? "Not measured") / \
                    Isolation \(isolation.map { String(describing: $0.state) } ?? "Not measured")
                    """
                )
                if let age = detail.age {
                    Text("Sender updated \(age)s ago\(detail.isStale ? " / Stale" : "")")
                }
                Text(
                    """
                    RTC RX: \(member.connectionState.rawValue) / \(member.authenticationState.rawValue) / \
                    \(detail.paths)
                    """
                )
                Text("Decode: \(member.activeCodec?.rawValue ?? "Not measured") / packets/s: Not measured")
                Text(presentation.playoutDetail(for: member.id))
                    .accessibilityIdentifier("receive-peer-playout")
                Text("Peer Bus: volume \(Int(detail.volume * 100))% / FX \(detail.effectSummary)")
            } else { Text("Offline").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
