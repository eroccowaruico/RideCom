import SwiftUI

/// Advanced's group settings, with the shared owner-aware group removal action last.
struct AdvancedGroupSettingsView: View {
    let viewModel: IntercomViewModel
    let groupID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?
    @State private var addingUsers = false
    @State private var invitationPerson: SavedUser?
    @State private var editingMember: GroupMember?
    @State private var pendingRemoval: PendingMemberRemoval?

    private var group: IntercomGroup? { viewModel.groups.first { $0.id == groupID && $0.kind == .group } }

    var body: some View {
        NavigationStack {
            Form {
                if let group {
                    Section("Name") {
                        TextField("Group name", text: Binding(get: { name ?? group.name }, set: { name = $0 }))
                            .accessibilityIdentifier("groupSettingsNameField")
                    }
                    Section {
                        ForEach(Array(group.members.dropFirst())) { member in
                            Group {
                                if let invitation = viewModel.outgoingGroupInvitation(forPendingMember: member.id, in: groupID),
                                   let personID = invitation.personID, let person = viewModel.contactPerson(personID) {
                                    Button { invitationPerson = person } label: {
                                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                            Text(verbatim: member.resolvedDisplayName)
                                            let sent = invitation.sent.map(String.init) ?? "nil"
                                            Text(verbatim: "\(invitation.direction.rawValue) · \(invitation.state.rawValue) · sent \(sent)")
                                                .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                                            Text(verbatim: "expiresAt \(Date(timeIntervalSince1970: invitation.expiresAt).formatted(.iso8601))")
                                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                        .accessibilityElement(children: .combine)
                                    }
                                    .accessibilityIdentifier("groupSettingsMember-\(member.id)")
                                } else { Label { Text(member.resolvedDisplayName) } icon: { DestinationAvatar(isGroup: false, diameter: 28) } }
                            }
                                .advancedMemberRowActions(edit: { editingMember = member }, pending: $pendingRemoval,
                                                  name: member.resolvedDisplayName) {
                                    viewModel.removeMember(member.id, from: groupID)
                                }
                        }
                        Button("Add Members", systemImage: "person.badge.plus") { addingUsers = true }
                            .disabled(!viewModel.canEditSavedGroups || group.members.count >= IntercomGroup.maximumMemberCount)
                            .accessibilityIdentifier("groupSettingsAddMembersButton")
                    } header: {
                        Text("Members")
                    } footer: {
                        // iPhone and iPad swipe the row (no long-press menu); a mouse cannot swipe, so a Mac right-clicks.
                        #if os(macOS)
                        Text("Control-click a member to rename or remove them.")
                        #endif
                    }
                    AdvancedGroupDeliveryRecords(records: viewModel.groupInvitationDeliveries(in: groupID))
                    if viewModel.canShareGroup(groupID) {
                        Section {
                            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "groupSettingsInviteButton")
                        }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("closeGroupSettingsButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let name, name != group?.name, !viewModel.renameGroup(groupID, to: name) { return }
                        dismiss()
                    }
                    .disabled(group == nil || !(name.map { IntercomGroup.isValidName($0) && !$0.contains("|") } ?? true))
                    .accessibilityIdentifier("saveGroupSettingsButton")
                }
            }
            .sheet(isPresented: $addingUsers) { SavedUsersView(viewModel: viewModel, groupID: groupID) }
            .sheet(item: $invitationPerson) { person in
                ContactPersonSheet(viewModel: viewModel, personID: person.id, onClose: { invitationPerson = nil })
            }
            .sheet(item: $editingMember) { member in
                GroupMemberNameView(viewModel: viewModel, groupID: groupID, member: member)
            }
            .memberRemoveConfirmation($pendingRemoval)
            .accessibilityIdentifier("groupSettingsView")
        }
        #if os(macOS)
        .frame(minWidth: 320, idealWidth: 480, minHeight: 400)
        #endif
    }
}
