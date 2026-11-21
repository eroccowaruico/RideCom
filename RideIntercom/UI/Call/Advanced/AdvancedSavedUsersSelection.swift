import SwiftUI

/// Advanced's selection of saved users: a row only selects, with a checkmark. Renaming and deleting
/// live in the user's own settings and the Users list.
struct AdvancedSavedUsersSelection: View {
    @Bindable var viewModel: IntercomViewModel
    let groupID: UUID?
    let onSaved: (UUID?, Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MemberSelection

    init(viewModel: IntercomViewModel, groupID: UUID?, onSaved: @escaping (UUID?, Set<UUID>) -> Void) {
        self.viewModel = viewModel
        self.groupID = groupID
        self.onSaved = onSaved
        _selection = State(initialValue: MemberSelection(viewModel: viewModel, groupID: groupID))
    }

    var body: some View {
        Form {
            if groupID == nil {
                Section("Group name") {
                    TextField(
                        "Group name", text: $selection.typedName,
                        prompt: selection.suggestedName.map { Text(verbatim: $0) }
                    )
                        .accessibilityIdentifier("savedUsersGroupNameField")
                }
            }
            Section("New People") { NewGroupInvitees(selection: $selection) }
            Section {
                ForEach(selection.users) { user in
                    let isSelected = selection.selected.contains(user.id)
                    Button { selection.toggle(user.id) } label: {
                        HStack {
                            Text(verbatim: user.resolvedDisplayName).foregroundStyle(.primary)
                            Spacer()
                            if isSelected { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    }
                    .directoryRowButtonStyle()
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("selectUser-\(user.id)")
                }

            } header: {
                Text("Saved Users")
            }
            Section {
                Text("\(selection.memberCount) of 8 members including you")
                if let message = selection.saveMessage {
                    Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger)
                        .accessibilityIdentifier("savedUsersErrorLabel")
                    InvitationStorageRecoveryButton(viewModel: viewModel)
                }
            }
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .navigationTitle(LocalizedStringKey(groupID == nil ? "New Group" : "Invite Members"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.accessibilityIdentifier("closeSavedUsersButton")
            }
            ToolbarItem(placement: .confirmationAction) {
                // A new group connects at once when no other call is live, so the button says so.
                Button(LocalizedStringKey(groupID != nil ? "Add Users"
                            : viewModel.hasAnyActiveGroupConnection ? "Create Group" : "Create and Connect")
                ) {
                    if case .some(let added) = selection.save() { onSaved(added, selection.selected) }
                }
                .disabled(!selection.canSave)
                .accessibilityIdentifier("saveUserSelectionButton")
            }
        }
    }
}
