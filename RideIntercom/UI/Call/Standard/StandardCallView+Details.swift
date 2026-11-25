import SwiftUI

extension StandardCallView {
    @ViewBuilder func callDetails(
        _ group: IntercomGroup,
        inviteMembers: @escaping () -> Void,
        openInvitation: @escaping (SavedUser) -> Void
    ) -> some View {
        if group.id == viewModel.activeGroupID {
            audioDetails(for: group.kind)
            if viewModel.isAudioPausedForDeviceChange, viewModel.canResumeAudioOnThisDevice {
                Section {
                    if viewModel.audioPauseError == nil { Text("Check your headphones or speaker, then resume audio.") }
                    Button("Resume Audio") { viewModel.resumeAudioAfterDeviceChange() }
                        .appProminentButtonStyle()
                        .accessibilityIdentifier("resumeAudioButton")
                }
            }
            if let notice = viewModel.audioRouteNotice { noticeSection(notice) }
            CallAppleEnrollmentButton(viewModel: viewModel, inList: true)
            if let notice = viewModel.connectivityNotice { noticeSection(notice) }
            if let error = viewModel.audioErrorMessage, viewModel.audioPauseError == nil { noticeSection(error) }
        }
        if group.kind == .group {
            membersSection(group, inviteMembers: inviteMembers, openInvitation: openInvitation)
        }
    }

    private func membersSection(
        _ group: IntercomGroup,
        inviteMembers: @escaping () -> Void,
        openInvitation: @escaping (SavedUser) -> Void
    ) -> some View {
        Section {
            if viewModel.canManageRegularGroups {
                Button("Invite Members", systemImage: "person.badge.plus", action: inviteMembers)
                    .disabled(group.members.count >= IntercomGroup.maximumMemberCount)
                    .accessibilityIdentifier("addSavedUsersButton")
            }
            if group.id == viewModel.activeGroupID {
                selfMemberRow
            }
            ForEach(Array(group.members.dropFirst())) { member in
                Group {
                    if let person = viewModel.personForGroupInvitation(memberID: member.id, groupID: group.id) {
                        Button { openInvitation(person) } label: {
                            HStack {
                                memberRow(member, in: group)
                                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("standardCallInvitee-\(member.id)")
                    } else if group.id == viewModel.activeGroupID, viewModel.authenticatedPeerIDs.contains(member.id) {
                        DisclosureGroup {
                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.remoteOutputVolume(for: member.id)) },
                                    set: { viewModel.setRemoteOutputVolume(peerID: member.id, volume: Float($0)) }
                                ),
                                in: 0...1
                            ) {
                                Text("Volume for \(member.resolvedDisplayName)")
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("standardPeerVolume-\(member.id)")
                        } label: {
                            memberRow(member, in: group)
                        }
                        .accessibilityIdentifier("standardPeerRow-\(member.id)")
                    } else {
                        memberRow(member, in: group)
                    }
                }
            }
        } header: {
            Text("People in This Call").accessibilityIdentifier("standardCallParticipantsHeading")
        }
    }

    private var selfMemberRow: some View {
        HStack {
            DestinationAvatar(isGroup: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("You")
                if viewModel.isMuted {
                    Text("Muted").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            StandardVoiceIndicator(kind: .input, level: viewModel.diagnosticsInputLevel,
                                   isSilenced: viewModel.isMuted, label: Text("Your voice"))
                .accessibilityIdentifier("standardVoiceIndicatorSelf")
        }
        .frame(minHeight: 44)
    }

    private func memberRow(_ member: GroupMember, in group: IntercomGroup) -> some View {
        HStack {
            HStack {
                if member.id.hasPrefix(GroupMember.pendingInvitePrefix) {
                    PendingAvatar()
                } else {
                    DestinationAvatar(isGroup: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.resolvedDisplayName)
                    if let invitation = StandardGroupInvitationStatus(viewModel: viewModel, memberID: member.id,
                                                                      groupID: group.id, includeReceived: false) {
                        invitation.font(.footnote).foregroundStyle(.secondary)
                    } else if group.id == viewModel.activeGroupID {
                        memberState(member)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            // Only someone in the conversation has a voice to show; still and grey while quiet.
            if group.id == viewModel.activeGroupID, viewModel.authenticatedPeerIDs.contains(member.id) {
                StandardVoiceIndicator(kind: .peer, level: member.voiceLevel, isSilenced: member.isMuted,
                                       label: Text("\(member.resolvedDisplayName)'s voice"))
                    .accessibilityIdentifier("standardVoiceIndicator-\(member.id)")
            }
        }
        .frame(minHeight: 44)
    }

    /// One state word under the name while in this call: speaking, connecting, or not connected.
    /// Connected and quiet needs no word. Color never carries the state alone.
    @ViewBuilder private func memberState(_ member: GroupMember) -> some View {
        Group {
            if member.isTalking {
                // The word goes with the indicator's steps; color alone never says who is speaking.
                Text("Speaking")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("standardMemberSpeaking-\(member.id)")
            } else if viewModel.authenticatedPeerIDs.contains(member.id) {
                if member.isMuted { Text("Muted").foregroundStyle(.secondary) }
            } else if viewModel.connectedPeerIDs.contains(member.id) {
                // Reached but not yet verified: not part of the conversation yet.
                Text("Connecting")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("standardMemberConnecting-\(member.id)")
            } else {
                // The live peer sets, not the stored member state, say who has joined.
                Text("Not connected right now")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("standardMemberNotConnected-\(member.id)")
            }
        }
        .font(.footnote)
    }

    /// The slider uses the space between the output indicators, with a visual reference at 100%.
    private func audioDetails(for kind: IntercomGroup.Kind) -> some View {
        Section {
            HStack(spacing: AppSpacing.small) {
                Image(systemName: "speaker").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { Double(viewModel.overallOutputVolume) },
                        set: { viewModel.setOverallOutputVolume(Float($0)) }
                    ),
                    in: 0...2
                ) {
                    Text("Volume")
                }
                .labelsHidden()
                // SwiftUI slider ticks define selectable values. The midpoint is a visual reference.
                .overlay(alignment: .bottom) {
                    Capsule().fill(.secondary).frame(width: 2, height: 4)
                        .offset(y: 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .accessibilityIdentifier("standardVolumeSlider")
                // What actually plays, so a moving symbol you cannot hear points at the volume or device.
                StandardVoiceIndicator(kind: .output, level: viewModel.diagnosticsOutputLevel,
                                       isSilenced: viewModel.isOutputMuted, label: Text("Output"))
                    .accessibilityIdentifier("standardVoiceIndicatorOutput")
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            if viewModel.supportsSoundIsolation {
                Toggle(isOn: Binding(get: { viewModel.receiveMixSoundIsolationEnabled },
                                     set: viewModel.setReceiveMixSoundIsolationEnabled)) {
                    let label: LocalizedStringKey = kind == .direct
                        ? "Isolate the Other Person’s Voice" : "Isolate Incoming Voices"
                    Text(label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("standardReceiveVoiceIsolationToggle")
            }
        }
    }

    private func noticeSection(_ message: String) -> some View {
        Section { Label(LocalizedStringKey(message), systemImage: "exclamationmark.circle") }
    }
}
