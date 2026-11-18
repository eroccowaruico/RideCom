import SwiftUI

/// The local person's identity owns this sheet from unsaved input to confirmed registration.
/// Native sharing is a child presentation, so cancelling it never dismisses this sheet.
struct ContactPersonSheet: View {
    let viewModel: IntercomViewModel
    let personID: UUID
    var onClose: (() -> Void)? = nil
    @State private var saved = false

    private var person: SavedUser? { viewModel.contactPerson(personID) }

    var body: some View {
        NavigationStack {
            Group {
                if let person {
                    if viewModel.interfaceMode == .advanced {
                        AdvancedContactPersonDetail(viewModel: viewModel, person: person, presentationPersonID: personID)
                    } else {
                        StandardContactPersonDetail(viewModel: viewModel, person: person, presentationPersonID: personID)
                    }
                } else if !saved {
                    ContactPersonCreation(viewModel: viewModel, personID: personID) { saved = true }
                } else {
                    Form { Text("This person is no longer saved.") }.formStyle(.grouped)
                }
            }
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle(person == nil && !saved ? Text("Add Person") : Text(verbatim: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(person == nil && !saved ? "Cancel" : "Done") {
                        if let onClose { onClose() }
                        else { viewModel.dismissContactInvitationPresentation(expectedPresentationID: "person-" + personID.uuidString) }
                    }
                    .accessibilityIdentifier("closeContactInvitationButton")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("contactInvitationSheet")
        }
        .interactiveDismissDisabled()
        .onChange(of: person?.id) { _, current in
            if current != nil { saved = true }
            else if saved {
                if let onClose { onClose() }
                else { viewModel.dismissContactInvitationPresentation(expectedPresentationID: "person-" + personID.uuidString) }
            }
        }
        .onAppear {
            if person != nil { saved = true }
            viewModel.resumeContactPersonInvitation(personID)
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 320)
        #endif
    }
}

/// Identical input and explicit save in both modes. No focus/disappear persistence.
private struct ContactPersonCreation: View {
    let viewModel: IntercomViewModel
    let personID: UUID
    let onSaved: () -> Void
    @State private var name = ""
    @State private var candidate = ""
    @FocusState private var nameFocused: Bool

    private var effectiveName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? candidate : typed
    }

    var body: some View {
        Form {
            Section {
                TextField("Their Name", text: $name, prompt: Text(verbatim: candidate))
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { nameFocused = false }
                    .accessibilityIdentifier("contactInvitationNameField")
            } header: { Text("Their Name") } footer: {
                Text("This is your name for them. It also appears in the invitation message you share. If you leave it empty, it will be \(candidate).")
            }
            if let message = viewModel.contactInvitationMessage {
                Section {
                    Text(LocalizedStringKey(message)).accessibilityIdentifier("contactInvitationMessage")
                    if viewModel.groupStorageIssue != nil {
                        if let reason = viewModel.groupErrorMessage { Text(LocalizedStringKey(reason)) }
                        Button("Reload Saved Groups") { viewModel.reloadSavedGroups() }
                            .accessibilityIdentifier("reloadContactPersonStorageButton")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            Button("Save") {
                if viewModel.saveContactPerson(personID, name: effectiveName, usesProvisionalName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    nameFocused = false
                    onSaved()
                }
            }
            .appProminentButtonStyle()
            .disabled(!viewModel.canEditSavedGroups)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("saveContactPersonButton")
            .padding(.horizontal, AppSpacing.screen)
            .padding(.vertical, AppSpacing.s)
        }
        .onAppear {
            guard candidate.isEmpty else { return }
            candidate = ProvisionalName.candidate(avoiding: Set(viewModel.directoryUsers.map(\.resolvedDisplayName)))
            nameFocused = true
        }
    }
}

struct ContactPersonShareButton: View {
    let viewModel: IntercomViewModel
    let person: SavedUser

    var body: some View {
        ContactInvitationShareButton(viewModel: viewModel, title: "Share Invitation", personName: person.resolvedDisplayName) {
            try viewModel.prepareContactPersonShare(person.id, expectedAccountAccessID: viewModel.accountAccessID)
        }
        .appProminentButtonStyle()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.screen)
        .padding(.vertical, AppSpacing.s)
    }
}
