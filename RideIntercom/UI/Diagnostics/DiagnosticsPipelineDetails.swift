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
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
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
    @Bindable var viewModel: IntercomViewModel
    let presentation: ReceivePipelinePresentation
    @Binding var expandedStage: String?

    var body: some View {
        let members = presentation.receiveParticipants
        let states = presentation.receivePeerStates
        VStack(alignment: .leading, spacing: AppSpacing.m) {
            Text("Participants").font(.headline).accessibilityIdentifier("receive-mix-topology")
            if members.isEmpty { Text("No participants") }
            ForEach(members.filter { states[$0.id] == nil }) { member in
                participant(member, state: nil)
            }
            if states.isEmpty {
                CompactPipelineStepRow(step: presentation.receiveMixStep)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: AppSpacing.m) {
                        ForEach(members.filter { states[$0.id] != nil }) { member in
                            branch { participant(member, state: states[member.id]) }
                        }
                    }
                    .padding(.bottom, AppSpacing.m)
                    .overlay(alignment: .leading) {
                        connectionLine.frame(width: 1).padding(.top, AppSpacing.m)
                    }
                    branch { CompactPipelineStepRow(step: presentation.receiveMixStep) }
                        .overlay(alignment: .topLeading) {
                            connectionLine.frame(width: 1, height: AppSpacing.m)
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
            .padding(.leading, AppSpacing.l + AppSpacing.xs)
            .overlay(alignment: .topLeading) {
                connectionLine
                    .frame(width: AppSpacing.l, height: 1)
                    .padding(.top, AppSpacing.m)
            }
    }

    private func participant(_ member: GroupMember, state: PipelineStepState?) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedStage == "receive-peers" || expandedStage == member.id },
            set: { expandedStage = $0 ? member.id : nil }
        )) {
            peer(member)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
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
        let status = viewModel.remoteRuntimeStatuses[member.id]
        let paths = viewModel.networkDiagnostics?.peers.filter { $0.peerID.rawValue == member.id } ?? []
        let codecReport = status?.packageReports.first { $0.package == "Codec" }.flatMap { try? $0.decodeJSON(CodecRuntimeReport.self) }
        let vad = status?.packageReports.first { $0.package == "VADGate" }.flatMap { try? $0.decodeJSON(VADGateRuntimeSnapshot.self) }
        let effects = viewModel.receivePeerEffectChainSnapshot(peerID: member.id)
        let isolation = status?.packageReports.first { $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot" }.flatMap { try? $0.decodeJSON(VoiceIsolationRuntimeSnapshot.self) }
        return VStack(alignment: .leading, spacing: AppSpacing.xs) {
            if member.connectionState != .offline {
                if status?.localMute == true {
                    Label { Text("Muted") } icon: { Image(systemName: "mic.slash.fill").foregroundStyle(AppColorPalette.danger) }
                }
                Text("Sender: \(status.map { $0.localMute ? "Muted" : "Unmuted" } ?? "Not measured") / codec \(codecReport.map { $0.activeConfiguration.codec.rawValue } ?? "Not measured") / bitrate \(codecReport?.activeConfiguration.activeBitRate.map { "\($0) bps" } ?? "Not measured") / VAD \(vad?.lastAnalysis.map { String(describing: $0.state) } ?? "Not measured") / Isolation \(isolation.map { String(describing: $0.state) } ?? "Not measured")")
                if let status {
                    let age = max(0, Date().timeIntervalSince1970 - status.generatedAt)
                    Text("Sender updated \(Int(age))s ago\(age > 15 ? " / Stale" : "")")
                }
                Text("RTC RX: \(member.connectionState.rawValue) / \(member.authenticationState.rawValue) / \(paths.isEmpty ? "Path not measured" : paths.map { $0.route == .webRTC ? "Internet" : ($0.path.count > 2 ? "Local relayed" : "Local direct") }.joined(separator: ", "))")
                Text("Decode: \(member.activeCodec?.rawValue ?? "Not measured") / packets/s: Not measured")
                Text("Peer Bus: volume \(Int(viewModel.remoteOutputVolume(for: member.id) * 100))% / FX \(effects.summary) / queued \(member.queuedAudioFrameCount) frames")
            } else { Text("Offline").foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
