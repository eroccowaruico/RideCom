import SwiftUI

/// Opens one invitation: naming and sending a new one, or each mode's own detail.
/// The modes share only the data and operations; each detail lives in its mode's folder.
struct ContactInvitationSheet: View {
    let viewModel: IntercomViewModel
    let invitationID: UUID
    private var isAdvanced: Bool { viewModel.interfaceMode == .advanced }

    var body: some View {
        NavigationStack {
            Group {
                if let record = viewModel.contactInvitationRecord(invitationID) {
                    if isAdvanced {
                        AdvancedContactInvitationDetail(viewModel: viewModel, record: record)
                    } else {
                        StandardContactInvitationDetail(viewModel: viewModel, record: record)
                    }
                } else {
                    Form { Text("This invitation is no longer available.") }.formStyle(.grouped)
                }
            }
            .screenBackground(AppColorPalette.listScreenBackground)
            // Standard's detail has no title: the name is its heading. A verbatim empty title adds no catalog key.
            .navigationTitle(isAdvanced ? Text("Contact Invitation") : Text(verbatim: ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        viewModel.dismissContactInvitationPresentation(
                            expectedPresentationID: "share-" + invitationID.uuidString)
                    }
                    .accessibilityIdentifier("closeContactInvitationButton")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("contactInvitationSheet")
        }
        .interactiveDismissDisabled()
        .onDisappear {
            viewModel.contactInvitationSheetDidDisappear(invitationID)
        }
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 320)
        #endif
    }
}

/// Preparing a link leaves it unsent until the system activity succeeds.
struct ContactInvitationShareButton: View {
    let viewModel: IntercomViewModel
    let title: LocalizedStringKey
    let personName: String
    let prepare: @MainActor () throws -> PreparedContactInvitationShare
    @State private var share: PreparedContactInvitationShare?

    var body: some View {
        Button {
            guard share == nil else { return }
            do {
                share = try prepare()
                viewModel.contactInvitationMessage = nil
            } catch {
                viewModel.contactInvitationMessage = "Could not prepare this invitation. Try again."
            }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .background {
            ContactInvitationActivity(
                share: share, message: String(localized: "RideCom invitation for \(personName)")
            ) { prepared, completed in
                if completed { viewModel.completeContactInvitationSharing(prepared) }
                share = nil
            }
        }
        .accessibilityIdentifier("shareContactInvitationButton")
    }
}

struct ContactInvitationAcceptanceView: View {
    let viewModel: IntercomViewModel
    let preview: ContactInvitationPreview
    let onAccepted: () -> Void

    @State private var registeredPersonID: UUID?
    private var person: SavedUser? { registeredPersonID.flatMap { viewModel.contactPerson($0) } }

    var body: some View {
        NavigationStack {
            Group {
                if let person, let registeredPersonID {
                    if viewModel.interfaceMode == .advanced {
                        AdvancedContactPersonDetail(
                            viewModel: viewModel, person: person, presentationPersonID: registeredPersonID)
                    } else {
                        StandardContactPersonDetail(
                            viewModel: viewModel, person: person, presentationPersonID: registeredPersonID)
                    }
                } else {
                    Form {
                        Section {
                            Text(preview.inviterName).font(.title2)
                            Text(
                                """
                                Registering saves this person to Users. \
                                Declining closes this invitation \
                                without saving or notifying them. Your current call stays connected.
                                """
                            )
                            if let groupName = preview.invitedGroupName {
                                Text("Registering also adds \(groupName) to Groups.").accessibilityIdentifier(
                                    "invitedGroupPreview")
                            }
                            if let message = viewModel.contactInvitationMessage { Text(LocalizedStringKey(message)) }
                            InvitationStorageRecoveryButton(viewModel: viewModel)
                        }
                    }
                    .formStyle(.grouped)
                    .accessibilityIdentifier("contactInvitationPreview")
                }
            }
            .screenBackground(AppColorPalette.listScreenBackground)
            .navigationTitle(person == nil ? Text("Contact Invitation") : Text(verbatim: ""))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(person == nil ? "Decline" : "Done") {
                        viewModel.dismissContactInvitationPresentation(
                            expectedPresentationID: "accept-" + preview.id.uuidString)
                    }
                    .accessibilityIdentifier(
                        person == nil ? "cancelContactInvitationButton" : "closeContactInvitationButton")
                }
                if person == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Register") {
                            if viewModel.acceptPresentedContactInvitation(
                                expectedInvitationID: preview.id, keepingPresentation: true) {
                                registeredPersonID = viewModel.contactInvitationRecord(preview.id)?.personID
                                onAccepted()
                            }
                        }.accessibilityIdentifier("acceptContactInvitationButton")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        #if os(macOS)
        .frame(minWidth: 360, idealWidth: 460, minHeight: 280)
        #endif
    }
}
