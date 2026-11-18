import SwiftUI

/// Choosing saved users for a new group or for an existing one. Each mode has its own selection
/// screen; both share the selection's data and operations and the invitation step that follows.
struct SavedUsersView: View {
    @Bindable var viewModel: IntercomViewModel
    var groupID: UUID?
    @Environment(\.dismiss) private var dismiss
    /// Set once saved users were committed to this group. Adding them only lists
    /// them here; their devices get the group key from the shared invitation.
    @State private var selectedUsers: Set<UUID> = []
    @State private var invitationGroupID: UUID?
    private var invitationGroup: IntercomGroup? { viewModel.groups.first { $0.id == invitationGroupID } }

    var body: some View {
        NavigationStack {
            if let group = invitationGroup {
                invitationStep(group)
            } else if viewModel.interfaceMode == .advanced {
                AdvancedSavedUsersSelection(viewModel: viewModel, groupID: groupID, onSaved: finish)
            } else {
                StandardMemberSelection(viewModel: viewModel, groupID: groupID, onSaved: finish)
            }
        }
        .interactiveDismissDisabled()
        // A group removed during the invitation step has nothing left to share.
        .onChange(of: invitationGroupID != nil && invitationGroup == nil) { _, removed in if removed { dismiss() } }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 360)
        #endif
    }

    /// Creating selects the new group. Only added people need the invitation.
    private func finish(_ addedTo: UUID?, selectedUsers: Set<UUID>) {
        self.selectedUsers = selectedUsers
        if let addedTo { invitationGroupID = addedTo } else { dismiss() }
    }

    /// Keep delivery status and optional sharing in the same saved step.
    private func invitationStep(_ group: IntercomGroup) -> some View {
        Form {
            let people = viewModel.groupInvitationPersonIDs(group.id)
            if !people.isEmpty {
                Section {
                    Text(verbatim: group.name).font(.headline)
                    Text("Invitations saved. Share each person's invitation. Cancelling sharing keeps the saved people and invitations.")
                    ForEach(people, id: \.self) { personID in
                        if let person = viewModel.contactPerson(personID) {
                        NavigationLink {
                            if viewModel.interfaceMode == .advanced {
                                AdvancedContactPersonDetail(viewModel: viewModel, person: person, presentationPersonID: personID)
                            } else { StandardContactPersonDetail(viewModel: viewModel, person: person, presentationPersonID: personID) }
                        } label: { Text(verbatim: person.resolvedDisplayName) }
                        .accessibilityIdentifier("groupInvitePerson-\(personID)")
                        }
                    }
                }
            }
            if !selectedUsers.isEmpty {
            if !viewModel.groupInvitationDeliveries(for: selectedUsers, in: group.id).isEmpty {
                if viewModel.interfaceMode == .advanced {
                    AdvancedRegisteredGroupInvitations(viewModel: viewModel, group: group, selectedUsers: selectedUsers)
                } else { StandardRegisteredGroupInvitations(viewModel: viewModel, group: group, selectedUsers: selectedUsers) }
            } else {
            Section {
                Text("Send the group invitation to the people you added. When they open it, \(group.name) and its key are added on their device, and you can talk nearby without the Internet.")
                    .accessibilityIdentifier("sendGroupInvitationMessage")
                CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton", bindsToGroup: true)
            } footer: {
                Text("Adding people only lists them on this device. You can send the invitation later from Invite.")
            }
            }
            }
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .navigationTitle(LocalizedStringKey("Share Invitations"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("finishAddingUsersButton")
            }
        }
    }
}

/// The selection's data and its save operation, shared by both modes' selection screens.
struct MemberSelection {
    let viewModel: IntercomViewModel
    let groupID: UUID?
    let suggestedName: String?
    let newGroupID = UUID()
    var newPeople: [GroupInvitationDraft] = []
    var selected: Set<UUID> = []
    var typedName = ""

    init(viewModel: IntercomViewModel, groupID: UUID?) {
        self.viewModel = viewModel
        self.groupID = groupID
        guard groupID == nil else { suggestedName = nil; return }
        // One editable name per creation sheet. Picking people never replaces it.
        var name: String
        repeat {
            let code = String(UUID().uuidString.prefix(6))
            name = String(localized: "Group \(code)")
        } while viewModel.groups.contains(where: { $0.name == name })
        suggestedName = name
        typedName = name
    }

    var users: [SavedUser] {
        let savedID = groupID ?? (viewModel.groups.contains(where: { $0.id == newGroupID }) ? newGroupID : nil)
        return viewModel.availableUsers(for: savedID)
    }

    var groupName: String {
        let typed = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (suggestedName ?? "") : typed
    }

    var memberCount: Int {
        (viewModel.groups.first { $0.id == (groupID ?? newGroupID) }?.members.count ?? 1)
        + users.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.groupMemberIDs.count }
        + newPeople.filter { viewModel.contactPerson($0.id) == nil }.count
    }

    var canSave: Bool {
        viewModel.canEditSavedGroups && memberCount <= IntercomGroup.maximumMemberCount
            && newPeople.allSatisfy { IntercomGroup.isValidName($0.resolvedName) }
            && (groupID == nil ? IntercomGroup.isValidName(groupName) && !groupName.contains("|") : !selected.isEmpty || !newPeople.isEmpty)
    }

    mutating func addNewPerson() {
        guard memberCount < IntercomGroup.maximumMemberCount else { return }
        let avoided = Set(viewModel.directoryUsers.map(\.resolvedDisplayName) + newPeople.map(\.resolvedName))
        newPeople.append(.init(suggestedName: ProvisionalName.candidate(avoiding: avoided)))
    }

    mutating func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Saves, then returns the group the people were added to, or nil when nobody was added.
    /// Returns `.none` when saving failed.
    func save() -> UUID?? {
        if !newPeople.isEmpty {
            guard canSave, let id = viewModel.saveGroupInvitations(groupID: groupID ?? newGroupID, creating: groupID == nil,
                name: groupName, selected: selected, newPeople: newPeople) else { return nil }
            return .some(.some(id))
        }
        let saved = if let groupID { viewModel.addSavedUsers(selected, to: groupID) }
                    else { viewModel.createTalkGroup(name: groupName, userIDs: selected, id: newGroupID) }
        guard saved else { return .none }
        return .some(selected.isEmpty ? nil : groupID ?? viewModel.selectedGroup?.id)
    }
}

/// A saved person's settings: each mode has its own screen.
struct UserSettingsView: View {
    let viewModel: IntercomViewModel
    let user: SavedUser

    var body: some View {
        if viewModel.interfaceMode == .advanced {
            AdvancedUserSettingsView(viewModel: viewModel, user: user)
        } else {
            StandardUserSettingsView(viewModel: viewModel, user: user)
        }
    }
}

/// The same explicit reload action wherever an invitation save needs recovery.
struct InvitationStorageRecoveryButton: View {
    let viewModel: IntercomViewModel
    var body: some View {
        if viewModel.groupStorageIssue != nil {
            Button("Reload Saved Groups") { viewModel.reloadSavedGroups() }
                .accessibilityIdentifier("reloadGroupInvitationStorageButton")
        }
    }
}

/// Identical new-person input and discard in both modes; saved-user selection stays mode-owned.
struct NewGroupInvitees: View {
    @Binding var selection: MemberSelection
    @FocusState private var focusedPerson: UUID?
    var body: some View {
        Group {
            Button("Invite Someone New", systemImage: "person.badge.plus") {
                selection.addNewPerson(); focusedPerson = selection.newPeople.last?.id
            }
            .disabled(selection.memberCount >= IntercomGroup.maximumMemberCount || !selection.viewModel.canEditSavedGroups)
            .accessibilityIdentifier("addNewGroupInviteeButton")
            ForEach($selection.newPeople) { $draft in
                HStack {
                    TextField("Their Name", text: $draft.name, prompt: Text(verbatim: draft.suggestedName))
                        .focused($focusedPerson, equals: draft.id).submitLabel(.done)
                        .onSubmit { focusedPerson = nil }
                        .accessibilityIdentifier("newGroupInviteName-\(draft.id)")
                    Button("Remove", systemImage: "minus.circle") {
                        if focusedPerson == draft.id { focusedPerson = nil }
                        selection.newPeople.removeAll { $0.id == draft.id }
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
        }
    }
}
