import SwiftUI

/// The group name and members, with the invitation action above the rows.
struct StandardGroupSettingsView: View {
    let viewModel: IntercomViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var invitingMembers = false
    @State private var invitationPerson: SavedUser?
    @State private var editingMember: GroupMember?
    @State private var pendingRemoval: PendingMemberRemoval?

    private var group: IntercomGroup? { viewModel.groups.first { $0.id == groupID && $0.kind == .group } }
    /// The name made from the members, as when the group was created.
    private var membersName: String {
        (group?.members.dropFirst().map(\.resolvedDisplayName) ?? []).formatted(.list(type: .and))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section("Name") {
                        TextField("Group name", text: Binding(get: { name ?? group.name }, set: { name = $0 }),
                                  prompt: Text(verbatim: membersName))
                            .accessibilityIdentifier("groupSettingsNameField")
                    }
                    Section {
                        if viewModel.canManageRegularGroups {
                            Button { invitingMembers = true } label: {
                                HStack(spacing: AppSpacing.m) {
                                    PendingAvatar(diameter: 28)
                                    Text("Invite Members")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.borderless)
                            .disabled(group.members.count >= IntercomGroup.maximumMemberCount)
                            .accessibilityIdentifier("groupSettingsAddMembersButton")
                        }
                        HStack(spacing: AppSpacing.m) {
                            DestinationAvatar(isGroup: false, diameter: 28).accessibilityHidden(true)
                            Text("You")
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("groupSettingsSelf")
                        ForEach(Array(group.members.dropFirst())) { member in
                            // The tap opens the member's own page; the swipe removes them.
                            Button {
                                if let person = viewModel.personForGroupInvitation(
                                    memberID: member.id, groupID: groupID)
                                {
                                    invitationPerson = person
                                } else {
                                    editingMember = member
                                }
                            } label: {
                                HStack(spacing: AppSpacing.m) {
                                    if member.id.hasPrefix(GroupMember.pendingInvitePrefix) {
                                        PendingAvatar(diameter: 28).accessibilityHidden(true)
                                    } else {
                                        DestinationAvatar(isGroup: false, diameter: 28).accessibilityHidden(true)
                                    }
                                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                                        Text(verbatim: member.resolvedDisplayName).lineLimit(2)
                                        if let invitation = StandardGroupInvitationStatus(viewModel: viewModel,
                                                                                          memberID: member.id, groupID: groupID) {
                                            invitation
                                                .font(.subheadline).foregroundStyle(.secondary)
                                                .accessibilityIdentifier("groupSettingsInvitationState-\(member.id)")
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                                }
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("groupSettingsMember-\(member.id)")
                            .standardMemberRowActions(canRemove: viewModel.canManageRegularGroups, pending: $pendingRemoval,
                                                      name: member.resolvedDisplayName) {
                                viewModel.removeMember(member.id, from: groupID)
                            }
                        }
                    } header: {
                        Text("Members")
                    }
                    GroupRemovalSection(viewModel: viewModel, group: group, onRemoved: { dismiss() })
                    if let message = viewModel.groupErrorMessage {
                        Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                            .accessibilityIdentifier("groupSettingsError")
                    }
                } else {
                    ContentUnavailableView("This group is no longer available.", systemImage: "person.3")
                }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("Group Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeGroupSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    // An emptied name saves the name made from the members.
                    Button("Done") {
                        let typed = name.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        let saved = typed?.isEmpty == true ? membersName : typed
                        if let saved, saved != group?.name, !viewModel.renameGroup(groupID, to: saved) { return }
                        dismiss()
                    }
                    .disabled(group == nil || name?.contains("|") == true || (name?.isEmpty == true && membersName.isEmpty))
                    .accessibilityIdentifier("saveGroupSettingsButton")
                }
            }
            .sheet(isPresented: $invitingMembers) { SavedUsersView(viewModel: viewModel, groupID: groupID) }
            .sheet(item: $invitationPerson) { person in
                ContactPersonSheet(viewModel: viewModel, personID: person.id, onClose: { invitationPerson = nil })
            }
            .sheet(item: $editingMember) { member in
                StandardGroupMemberView(viewModel: viewModel, groupID: groupID, member: member)
            }
            .memberRemoveConfirmation($pendingRemoval)
            .accessibilityIdentifier("groupSettingsView")
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400)
        #endif
    }
}
