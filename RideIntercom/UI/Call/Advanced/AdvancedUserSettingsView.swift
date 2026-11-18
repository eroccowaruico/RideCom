import SwiftUI

/// Advanced user settings: the implementation's names, the stored shared name, call requests and the call invite.
struct AdvancedUserSettingsView: View {
    @Bindable var viewModel: IntercomViewModel
    let user: SavedUser
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var confirmsDelete = false
    @State private var nameChoiceSaved = false

    init(viewModel: IntercomViewModel, user: SavedUser) {
        self.viewModel = viewModel; self.user = user
        _name = State(initialValue: user.localName ?? "")
    }

    private var currentUser: SavedUser { viewModel.savedUsers.first { $0.id == user.id } ?? user }
    /// Deleting the person ends a call with them, so the confirmation says so.
    private var endsCall: Bool { viewModel.isInCall(with: .user(user.id)) }

    private var typed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasUncommittedNameEdit: Bool { typed != (currentUser.localName ?? "") }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name on this device", text: $name, prompt: Text(verbatim: currentUser.displayName)).accessibilityIdentifier("savedUserNameField")
                if currentUser.isRegistered {
                LabeledContent("Name shared by this person", value: currentUser.displayName)
                    .accessibilityIdentifier("savedUserOriginalName")
                if !currentUser.needsNameConfirmation && currentUser.localName != nil {
                Button("Use Shared Name") {
                    if viewModel.resetSavedUserName(user.id) { dismiss() }
                }
                .accessibilityIdentifier("resetUserNameButton")
                Text("Your name for this person stays on this device. Use Shared Name removes your edit and follows their name updates.").font(.footnote)
                }
                }
                AdvancedContactNameConfirmation(viewModel: viewModel, person: currentUser,
                    allowsConfirmation: !hasUncommittedNameEdit, onResolved: { useShared in
                        name = useShared ? "" : (currentUser.localName ?? "")
                        nameChoiceSaved = true
                    })
                ForEach(viewModel.contactPersonInvitations(user.id)) { record in
                    AdvancedContactInvitationContent(viewModel: viewModel, record: record, personID: user.id)
                }
                if let call = viewModel.existingDirectCall(for: user.id), viewModel.canShareGroup(call.id) {
                    Section {
                        CallInvitationButton(viewModel: viewModel, group: call, accessibilityIdentifier: "userSettingsInviteButton")
                    }
                }
                Section {
                    Button("Delete User", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                        .disabled(!viewModel.canEditSavedGroups)
                        .accessibilityIdentifier("deleteUserButton")
                }
                if let message = viewModel.groupErrorMessage { Text(LocalizedStringKey(message)).foregroundStyle(AppColorPalette.danger) }
            }
            .formStyle(.grouped)
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle("User Settings")
            .accessibilityIdentifier("userSettingsView")
            .alert("Delete User?", isPresented: $confirmsDelete) {
                Button(endsCall ? "Disconnect and Delete" : "Delete User", role: .destructive) {
                    if viewModel.removeSavedUser(user.id) { dismiss() }
                }
                .accessibilityIdentifier("confirmDeleteUserButton")
                Button("Cancel", role: .cancel) { }
            } message: {
                if endsCall { Text("The current connection ends.") }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(nameChoiceSaved && !hasUncommittedNameEdit ? "Done" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("closeUserSettingsButton")
                }
                if !nameChoiceSaved || hasUncommittedNameEdit {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let saved = typed.isEmpty || typed == currentUser.displayName
                            ? viewModel.resetSavedUserName(user.id)
                            : viewModel.renameSavedUser(user.id, displayName: typed)
                        if saved { dismiss() }
                    }
                    .disabled(!typed.isEmpty && !IntercomGroup.isValidName(typed))
                    .accessibilityIdentifier("saveUserNameButton")
                }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 300, idealWidth: 480, minHeight: 280)
        #endif
    }
}
