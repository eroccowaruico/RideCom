import CallControl
import SwiftUI

struct StandardCallView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    @State private var addingUsers: IntercomGroup?
    @State private var invitationPerson: SavedUser?
    @State private var pendingEndReference: CallReference?
    @State private var confirmsEnd = false
    @State private var endingCallName = ""

    var body: some View {
        CallHeightLayout { compactHeight, regularWidth in
            if compactHeight, dynamicTypeSize.isAccessibilitySize, let group = viewModel.selectedGroup {
                VStack(spacing: 0) {
                    List {
                        Section {
                            accessibleCompactHero(group)
                        }
                        CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
                        CallStorageSection(viewModel: viewModel)
                        detailSections(group)
                        CallErrorSection(viewModel: viewModel, offersDirectInvitationRecovery: true)
                    }
                    .frame(maxHeight: .infinity)
                    .clipped()
                    .accessibilityIdentifier("standardCallDetailsScroll")
                    VStack {
                        primaryActions(group, compact: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppSpacing.screen)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("standardCallFixedControls")
                }
            } else if compactHeight || regularWidth, let group = viewModel.selectedGroup {
                HStack(alignment: .top, spacing: AppSpacing.screen) {
                    // Landscape: the left column takes 45% and holds the state and controls in its middle,
                    // as in the design sample; the details scroll on the right.
                    VStack(spacing: AppSpacing.medium) {
                        hero(group, compact: compactHeight)
                        primaryActions(group, compact: compactHeight)
                    }
                    .frame(maxWidth: AppSize.callColumnMaxWidth, maxHeight: compactHeight ? .infinity : nil)
                    .containerRelativeFrame(.horizontal) { length, _ in
                        compactHeight ? length * 0.45 : min(length, AppSize.callColumnMaxWidth)
                    }
                    List {
                        CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
                        CallStorageSection(viewModel: viewModel)
                        detailSections(group)
                        CallErrorSection(viewModel: viewModel, offersDirectInvitationRecovery: true)
                    }
                    .accessibilityIdentifier("standardCallDetailsScroll")
                    .frame(maxWidth: AppSize.callColumnMaxWidth)
                }
                .padding(.horizontal, AppSpacing.screen)
            } else {
                List {
                    CurrentCallSection(viewModel: viewModel, selectedTab: $selectedTab, excludesSelected: true)
                    CallStorageSection(viewModel: viewModel)
                    if let group = viewModel.selectedGroup {
                        // The glass card is its own section's row background: it lines up with the sections
                        // below, and the section's rounded clip falls on the card's edge.
                        Section {
                            hero(group, compact: false, card: false)
                                .padding(.vertical, AppSpacing.extraSmall)
                                .listRowBackground(StandardHeroCard.surface)
                                .listRowSeparator(.hidden)
                        }
                        Section {
                            primaryActions(group, compact: false)
                                // The row of controls spans the hero's width, as in the design sample.
                                .listRowInsets(.horizontal, AppSpacing.extraSmall)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        detailSections(group)
                    }
                    CallErrorSection(viewModel: viewModel, offersDirectInvitationRecovery: true)
                }
                // The hero sits right under the sheet's toolbar, as in the design sample.
                .contentMargins(.top, AppSpacing.small, for: .scrollContent)
                #if os(iOS)
                .listSectionSpacing(.compact)
                #endif
                .frame(maxWidth: AppSize.singleColumnMaxWidth)
            }
        }
        .screenBackground(AppColorPalette.callScreenBackground)
        .sensoryFeedback(.selection, trigger: viewModel.isMuted)
        .sensoryFeedback(.selection, trigger: viewModel.isOutputMuted)
        .sensoryFeedback(trigger: viewModel.hasAnyActiveGroupConnection) { old, new in
            old && !new ? .stop : nil
        }
        .sensoryFeedback(trigger: viewModel.callStatus(for: viewModel.activeGroupID)) { old, new in
            if new == .inCall && old != .inCall { return .success }
            if new == .audioPaused && old != .audioPaused { return .warning }
            return nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standardCallScreen")
        // Ending cannot be undone, so the question names the call, as the accessory's does.
        .alert(Text("Disconnect from \(endingCallName)?"), isPresented: $confirmsEnd) {
            Button("End Call", role: .destructive) {
                if let reference = pendingEndReference { viewModel.endCall(reference) }
                pendingEndReference = nil
            }.accessibilityIdentifier("standardConfirmEndCallButton")
            Button("Cancel", role: .cancel) { pendingEndReference = nil }
                .accessibilityIdentifier("standardCancelEndCallButton")
        }
        .sheet(item: $addingUsers) { group in SavedUsersView(viewModel: viewModel, groupID: group.id) }
        .sheet(item: $invitationPerson) { person in
            ContactPersonSheet(viewModel: viewModel, personID: person.id, onClose: { invitationPerson = nil })
        }
    }

    private func detailSections(_ group: IntercomGroup) -> some View {
        callDetails(
            group,
            inviteMembers: { addingUsers = group },
            openInvitation: { invitationPerson = $0 }
        )
    }

    @ViewBuilder private func primaryActions(_ group: IntercomGroup, compact: Bool) -> some View {
        let reference = viewModel.currentCallReference
        let access = viewModel.accountAccessID
        if group.id == viewModel.activeGroupID, viewModel.hasAnyActiveGroupConnection {
            let diameter = compact ? AppSize.callControlCompactDiameter : AppSize.callControlDiameter
            GlassEffectContainer(spacing: AppSpacing.callControls) {
                ViewThatFits(in: .horizontal) {
                    controlRow(
                        reference: reference, diameter: diameter, vertical: false,
                        horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize
                    )
                    controlRow(
                        reference: reference, diameter: diameter, vertical: true,
                        horizontalLabels: compact && dynamicTypeSize.isAccessibilitySize
                    )
                }
            }
            .frame(maxWidth: .infinity)
        } else if !viewModel.hasAnyActiveGroupConnection {
            // Connected elsewhere, there is no switch here: ending that call comes first.
            Button("Connect", systemImage: "phone") {
                viewModel.startCall(to: .group(group.id), accountAccessID: access)
            }
            .appProminentButtonStyle()
            .disabled(!viewModel.canStartCalls)
            .accessibilityIdentifier("standardConnectButton")
        }
    }

    private func controlRow(
        reference: CallReference,
        diameter: CGFloat,
        vertical: Bool,
        horizontalLabels: Bool
    ) -> some View {
        let controlLayout = horizontalLabels
            ? AnyLayout(HStackLayout(spacing: AppSpacing.extraSmall))
            : AnyLayout(VStackLayout(spacing: AppSpacing.medium))
        // Side by side, the three spread across the column with the outer ones at its edges;
        // End keeps at least 32pt from its neighbour.
        let layout = vertical
            ? AnyLayout(VStackLayout(spacing: AppSpacing.medium)) : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        // The glass style pads its label; the label is smaller so the visible circle is the diameter.
        let symbol = diameter - 2 * AppSize.callControlGlassPadding
        return layout {
            if viewModel.canControlMicrophone {
                controlLayout {
                    Button { viewModel.setCallMuted(!viewModel.isMuted, for: reference) } label: {
                        Image(systemName: "mic.slash").frame(width: symbol, height: symbol)
                    }
                    .modifier(CallMuteButtonStyle(isMuted: viewModel.isMuted))
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Mute Microphone")
                    .accessibilityValue(viewModel.isMuted ? "Muted" : "Unmuted")
                    .accessibilityAddTraits(viewModel.isMuted ? .isSelected : [])
                    .accessibilityIdentifier("standardMuteButton")
                    Text(viewModel.isMuted ? "Muted" : "Mute")
                        .font(AppTypography.footnoteStrong)
                        .fixedSize(horizontal: horizontalLabels, vertical: true)
                        .accessibilityIdentifier("standardMuteState")
                }
            } else {
                Label("Control the microphone on your Watch", systemImage: "applewatch")
                    .font(.caption).accessibilityIdentifier("standardMicrophoneStatus")
            }
            if !vertical { Spacer(minLength: AppSpacing.callControls) }
            outputControl(layout: controlLayout, symbol: symbol, horizontalLabels: horizontalLabels)
            if !vertical { Spacer(minLength: AppSpacing.destructiveSeparation) }
            controlLayout {
                Button(role: .destructive) {
                    pendingEndReference = reference
                    endingCallName = viewModel.groups.first { $0.id == viewModel.activeGroupID }
                        .map { viewModel.callTitle(for: $0) } ?? ""
                    confirmsEnd = true
                } label: {
                    Image(systemName: "phone.down.fill").frame(width: symbol, height: symbol)
                }
                .buttonStyle(.glassProminent).tint(AppColorPalette.danger)
                .buttonBorderShape(.circle)
                .accessibilityLabel("End Call")
                .accessibilityIdentifier("standardEndCallButton")
                Text("End").font(AppTypography.footnoteStrong)
                    .fixedSize(horizontal: horizontalLabels, vertical: true)
                    .accessibilityIdentifier("standardEndControlLabel")
            }
        }
    }

    private func outputControl(layout: AnyLayout, symbol: CGFloat, horizontalLabels: Bool) -> some View {
        layout {
            Button { viewModel.toggleOutputMute() } label: {
                Image(systemName: "speaker.slash").frame(width: symbol, height: symbol)
            }
            .modifier(
                CallMuteButtonStyle(isMuted: viewModel.isOutputMuted, tint: AppColorPalette.buttonProminentBackground)
            )
            .buttonBorderShape(.circle)
            // Silence, not "Speaker": the phone's Speaker switches where the sound goes.
            .accessibilityLabel("Silence")
            .accessibilityValue(viewModel.isOutputMuted ? "On" : "Off")
            .accessibilityAddTraits(viewModel.isOutputMuted ? .isSelected : [])
            .accessibilityIdentifier("standardSpeakerButton")
            Text(viewModel.isOutputMuted ? "Silenced" : "Silence").font(AppTypography.footnoteStrong)
                .fixedSize(horizontal: horizontalLabels, vertical: true)
                .accessibilityIdentifier("standardSpeakerControlLabel")
        }
    }
}

extension StandardCallView {
    /// The status hero: a glass card, leading-aligned, with the kind and size, the destination,
    /// the state and its reason. The route is not shown. VoiceOver reads it as one element.
    private func hero(_ group: IntercomGroup, compact: Bool, card: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: compact ? AppSpacing.extraExtraSmall : AppSpacing.extraSmall) {
            // At accessibility sizes the state must stay on screen with the controls.
            if !(compact && dynamicTypeSize.isAccessibilitySize) { kindLine(group) }
            Text(viewModel.callTitle(for: group))
                .font(AppTypography.destinationTitle)
                .lineLimit(2)
            // Words are never broken: when the symbol and state do not fit side by side, stack them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppSpacing.small) { statusSymbolView; statusTitle }
                VStack(alignment: .leading, spacing: AppSpacing.extraSmall) { statusSymbolView; statusTitle }
            }
            .font(.title3.weight(.semibold))
            .padding(.top, AppSpacing.extraExtraSmall)
            statusDetail
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StandardHeroCard(drawsSurface: card))
        .standardHeroAccessibility(kind: kindText(group), name: viewModel.callTitle(for: group),
                                   state: heroState.title, reason: heroState.detail)
    }

    /// Landscape at accessibility sizes: name and state side by side so the controls keep their room.
    private func accessibleCompactHero(_ group: IntercomGroup) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.screen) {
            Text(viewModel.callTitle(for: group))
                .font(AppTypography.destinationTitle)
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack {
                statusSymbolView
                VStack(alignment: .leading) {
                    statusTitle
                    statusDetail
                }
            }
            .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StandardHeroCard())
        .standardHeroAccessibility(kind: kindText(group), name: viewModel.callTitle(for: group),
                                   state: heroState.title, reason: heroState.detail)
    }

    /// The hero's words: the call's own state. A call notification never changes it.
    private var heroState: (title: String, detail: String?) {
        let status = viewModel.standardCallStatus
        let detail = status == .audioPaused ? viewModel.audioPauseError ?? status.detail : status.detail
        return (
            String(localized: .init(stringLiteral: status.title)),
            detail.map { String(localized: .init(stringLiteral: $0)) }
        )
    }

    /// The shared state symbol; the hero's larger type takes the larger progress.
    private var statusSymbolView: some View {
        CallStatusSymbol(status: viewModel.standardCallStatus, progressSize: .small)
    }

    private var statusTitle: some View {
        Text(verbatim: heroState.title)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func kindText(_ group: IntercomGroup) -> String {
        group.kind == .group ? String(localized: "Group · \(group.members.count) people") : String(localized: "User")
    }

    /// Kind and size above the name with the kind's symbol: "Group · 4 people" or "User".
    private func kindLine(_ group: IntercomGroup) -> some View {
        Label(kindText(group), systemImage: group.kind == .group ? "person.3.fill" : "person.fill")
            .font(AppTypography.subheadlineStrong)
            .foregroundStyle(.secondary)
    }

    /// The reason sits on its own line under the state instead of after a dash.
    @ViewBuilder private var statusDetail: some View {
        if let detail = heroState.detail {
            Text(verbatim: detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CallMuteButtonStyle: ViewModifier {
    let isMuted: Bool
    var tint: Color = AppColorPalette.danger
    @ViewBuilder func body(content: Content) -> some View {
        if isMuted {
            content.buttonStyle(.glassProminent).tint(tint)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// The hero's glass card. Standard only: Advanced draws its own call status.
private struct StandardHeroCard: ViewModifier {
    /// In a List the card is drawn as the row background instead (`surface`).
    var drawsSurface = true

    /// In a List the glass follows the section's corners. Elsewhere there is no container to be
    /// concentric with, so it uses the design sample's 18pt continuous corners.
    static var surface: some View { glass(in: ConcentricRectangle()) }

    private static func glass(in shape: some Shape) -> some View {
        shape.fill(.clear)
            #if os(macOS)
            // On Mac the hero is the one place that carries a faint brand tint.
            .glassEffect(.regular.tint(RideComColors.accent.opacity(0.08)), in: shape)
            #else
            .glassEffect(.regular, in: shape)
            #endif
    }

    func body(content: Content) -> some View {
        if drawsSurface {
            content.padding(AppSpacing.extraExtraLarge)
                .background(Self.glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous)))
        } else {
            content
        }
    }
}

private extension View {
    /// One element: the label names the destination, the value is the state and its reason.
    func standardHeroAccessibility(kind: String, name: String, state: String, reason: String?) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(kind), \(name)"))
            .accessibilityValue(Text(verbatim: [state, reason].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("standardCallHero")
    }
}
