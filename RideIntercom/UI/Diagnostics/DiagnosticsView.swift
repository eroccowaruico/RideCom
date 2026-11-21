import SwiftUI
import RTC

private enum DiagnosticsPage: String, CaseIterable, Identifiable {
    case overview = "Overview", transmit = "TX", receive = "RX", network = "Network", applied = "Applied"
    var id: String { rawValue }
}

struct DiagnosticsView: View {
    @Bindable var viewModel: IntercomViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page: DiagnosticsPage = .overview
    @State private var expandedStage: String?
    @State private var scrollTarget: String?

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            pageSelector
                .padding(.horizontal, AppSpacing.screen)
            GeometryReader { geometry in
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ScrollViewReader { proxy in
                        ScrollView {
                            GlassEffectContainer(spacing: AppSpacing.large) {
                                Group {
                                    if geometry.size.width >= AppSize.diagnosticsTwoColumnMinimumWidth
                                        && !dynamicTypeSize.isAccessibilitySize && page != .overview {
                                        HStack(alignment: .top, spacing: AppSpacing.large) {
                                            overviewContent
                                                .frame(maxWidth: AppSize.callColumnMaxWidth, alignment: .leading)
                                            pageContent
                                                .frame(maxWidth: AppSize.callColumnMaxWidth, alignment: .leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .top)
                                    } else {
                                        pageContent
                                            .frame(maxWidth: AppSize.singleColumnMaxWidth, alignment: .leading)
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .padding(AppSpacing.large)
                            }
                        }
                        .accessibilityIdentifier("diagnosticsScrollView")
                        .id(page)
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                        }
                    }
                }
            }
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .onAppear {
            viewModel.isDiagnosticsVisible = true
            viewModel.publishRuntimePackageReports(force: true)
        }
        .onDisappear { viewModel.isDiagnosticsVisible = false }
    }

    // Every page is visible at once as segments. Accessibility text sizes don't fit five segments,
    // so those sizes open the pages as a pushed selection list instead.
    @ViewBuilder private var pageSelector: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            NavigationLink {
                DiagnosticsPageSelection(page: $page)
            } label: {
                LabeledContent("Diagnostics", value: page.rawValue)
            }
            .accessibilityIdentifier("diagnosticsPagePicker")
        } else {
            pagePicker.pickerStyle(.segmented).labelsHidden()
        }
        #else
        pagePicker.pickerStyle(.segmented).labelsHidden()
        #endif
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .overview:
            overviewContent
        case .transmit:
            LiveTransmitPipelineView(viewModel: viewModel, expandedStage: $expandedStage)
        case .receive:
            LiveReceivePipelineView(viewModel: viewModel, expandedStage: $expandedStage)
        case .network:
            DiagnosticsNetworkView(viewModel: viewModel)
        case .applied:
            DiagnosticsAppliedView(viewModel: viewModel)
        }
    }

    // The former summary cards are retired; Overview is the pipeline summary and the symptom actions.
    private var overviewContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let steps = pipelineSteps(now: context.date.timeIntervalSince1970)
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                verdicts(transmit: steps.transmit, receive: steps.receive)
                pipelineOverview(transmit: steps.transmit, receive: steps.receive)
                participantsOverview
                networkOverview
                symptomButtons
            }
        }
    }

}

extension DiagnosticsView {
    private func pipelineSteps(now: TimeInterval) -> (transmit: [PipelineStep], receive: [PipelineStep]) {
        let input = DiagnosticsInput(viewModel, now: now)
        let transmit = TransmitPipelinePresentation(input: input)
        let receive = ReceivePipelinePresentation(input: input)
        return (transmit.flowSteps,
            [
                receive.rtcReceiveStep, receive.codecDecodeStep, receive.peerBusStep, receive.receiveMixStep,
                receive.outputBusStep, receive.outputEffectChainStep, receive.outputStep
            ]
        )
    }

    /// The conclusion first: one verdict per direction with the reason the stages report.
    private func verdicts(transmit: [PipelineStep], receive: [PipelineStep]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: AppSpacing.medium) {
                verdictRow("TX", verdict: PipelineVerdict(steps: transmit))
                verdictRow("RX", verdict: PipelineVerdict(steps: receive))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verdictRow(_ name: String, verdict: PipelineVerdict) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.extraSmall) {
            Label {
                Text(verbatim: "\(name): \(verdict.text)").font(.headline)
            } icon: {
                PipelineStateDot(state: verdict.state)
            }
            if let reason = verdict.reason {
                Text(verbatim: reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diagnosticsVerdict-\(name)")
    }

    private var pagePicker: some View {
        Picker("Diagnostics", selection: $page) {
            ForEach(DiagnosticsPage.allCases) { item in Text(item.rawValue).tag(item) }
        }
        .accessibilityIdentifier("diagnosticsPagePicker")
    }

    private func stageFlow(_ name: String, steps: [PipelineStep]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
            Text(verbatim: name).font(.subheadline.bold()).frame(minWidth: 28, alignment: .leading)
            WrappingRow(spacing: AppSpacing.extraSmall, lineSpacing: AppSpacing.extraSmall) {
                ForEach(steps) { step in
                    HStack(spacing: AppSpacing.extraSmall) {
                        if step.id != steps.first?.id {
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: step.state.statusSymbol)
                            .foregroundStyle(step.state.color)
                        Text(verbatim: step.title).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(
                verbatim: "\(name): " + steps.map { "\($0.title) \($0.state.statusText)" }.joined(separator: ", "))
        )
        .accessibilityIdentifier("diagnosticsStageDots-\(name)")
    }

    private var symptomButtons: some View {
        WrappingRow(spacing: AppSpacing.small, lineSpacing: AppSpacing.small) {
            Button("Others can't hear me") { navigate(.transmit, target: firstTransmitIssue) }
                .accessibilityIdentifier("diagnosticsOthersCannotHearButton")
            Button("I can't hear someone") { navigate(.receive, target: "receive-peers") }
                .accessibilityIdentifier("diagnosticsCannotHearButton")
            Button("Audio drops out") { navigate(.receive, target: "receive-input", expanding: "receive-peers") }
                .accessibilityIdentifier("diagnosticsAudioDropsButton")
            Button("Audio is delayed") { navigate(.receive, target: "receive-output") }
                .accessibilityIdentifier("diagnosticsAudioDelayedButton")
        }
        .buttonStyle(.glass)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func navigate(_ destination: DiagnosticsPage, target: String, expanding detail: String? = nil) {
        expandedStage = detail ?? target
        scrollTarget = nil
        page = destination
        DispatchQueue.main.async { scrollTarget = target }
    }

    private var firstTransmitIssue: String {
        let transmit = TransmitPipelinePresentation(input: DiagnosticsInput(viewModel))
        return transmit.flowSteps.first { $0.state != .passing }?.id ?? "session"
    }

    private func pipelineOverview(transmit: [PipelineStep], receive: [PipelineStep]) -> some View {
        GroupBox("Pipeline") {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                stageFlow("TX", steps: transmit)
                Divider()
                stageFlow("RX", steps: receive)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One row per other member: name, the measured path, and `PeerConnectionState` as stored.
    private var participantsOverview: some View {
        let members = Array(viewModel.selectedGroup?.members.dropFirst() ?? [])
        let peers = viewModel.networkDiagnostics?.peers ?? []
        return GroupBox {
            VStack(spacing: AppSpacing.small) {
                if members.isEmpty { Text("No participants").foregroundStyle(.secondary) }
                ForEach(members) { member in
                    let paths = peers.filter { $0.peerID.rawValue == member.id }
                        .map {
                            $0.route == .webRTC
                                ? "Internet" : ($0.path.count > 2 ? "Local · relayed" : "Local · direct")
                        }
                    overviewRow(member.resolvedDisplayName, value: paths.isEmpty ? "—" : paths.joined(separator: ", "),
                        state: PipelineStepState(member.connectionState), status: member.connectionState.rawValue
                    )
                        .opacity(member.connectionState == .offline ? 0.5 : 1)
                }
            }
        } label: {
            HStack {
                Text("Participants")
                Spacer()
                Text(verbatim: "\(members.count) \(members.count == 1 ? "member" : "members")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("diagnosticsOverviewParticipants")
    }

    /// One row per route: the route, how many peers use it, and its RTT.
    @ViewBuilder private var networkOverview: some View {
        if let report = viewModel.networkDiagnostics, !report.routes.isEmpty {
            GroupBox("Network") {
                VStack(spacing: AppSpacing.small) {
                    ForEach(report.routes, id: \.route.rawValue) { route in
                        let count = report.peers.filter { $0.route == route.route }.count
                        overviewRow(route.route == .webRTC ? "Internet" : "Local",
                                    value: "\(count) \(count == 1 ? "participant" : "participants")",
                                    state: count > 0 ? .passing : .idle,
                            status: "RTT "
                                + (route.statistics.roundTripTime.map { String(format: "%.0f ms", $0 * 1000) }
                                    ?? "Not measured"))
                    }
                }
            }
            .accessibilityIdentifier("diagnosticsOverviewNetwork")
        }
    }

    private func overviewRow(_ name: String, value: String, state: PipelineStepState, status: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
            Text(verbatim: name).font(.subheadline.bold()).lineLimit(2)
            Text(verbatim: value).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: AppSpacing.small)
            HStack(spacing: AppSpacing.extraSmall) {
                PipelineStateDot(state: state)
                Text(verbatim: status).font(.subheadline.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}

private extension PipelineStepState {
    init(_ connection: PeerConnectionState) {
        switch connection {
        case .connected: self = .passing
        case .connecting: self = .waiting
        case .offline: self = .idle
        }
    }
}

/// Places children left to right and wraps to a new line when the width runs out.
private struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let proposal = ProposedViewSize(width: bounds.width, height: nil)
        for (subview, origin) in zip(subviews, arrange(width: bounds.width, subviews: subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: proposal)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var columnOffset: CGFloat = 0, rowOffset: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            // Never wider than the line, so a long item wraps its own text instead of overflowing.
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if columnOffset > 0 && columnOffset + size.width > width {
                columnOffset = 0; rowOffset += lineHeight + lineSpacing; lineHeight = 0
            }
            origins.append(CGPoint(x: columnOffset, y: rowOffset))
            columnOffset += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, columnOffset - spacing)
        }
        return (origins, CGSize(width: min(widest, width), height: rowOffset + lineHeight))
    }
}

/// Eight-point state dot; Idle is a dashed ring so state never relies on color alone.
private struct PipelineStateDot: View {
    let state: PipelineStepState
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 8
    var body: some View {
        Group {
            if state == .idle {
                Circle().strokeBorder(state.color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
            } else {
                Circle().fill(state.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#if os(iOS)
private struct DiagnosticsPageSelection: View {
    @Binding var page: DiagnosticsPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(DiagnosticsPage.allCases) { item in
            Button {
                page = item
                dismiss()
            } label: {
                HStack {
                    Text(item.rawValue)
                    Spacer()
                    if page == item { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("diagnosticsPageSelection")
    }
}
#endif
