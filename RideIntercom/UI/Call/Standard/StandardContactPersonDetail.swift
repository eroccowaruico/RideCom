import SwiftUI

struct StandardContactPersonDetail: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    let presentationPersonID: UUID
    @State private var editsName = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: AppSpacing.s) {
                    if person.isRegistered { DestinationAvatar(isGroup: false, diameter: 56) }
                    else { PendingAvatar(diameter: 56) }
                    Text(verbatim: person.resolvedDisplayName).font(.title2.bold())
                        .accessibilityIdentifier("contactPersonSavedName")
                    Text(person.isRegistered ? "Registered" : "Not registered").font(.headline)
                        .accessibilityIdentifier("contactPersonRegistrationState")
                    if !person.isRegistered { Text("You can call each other after they register.") }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.s)
            }
            StandardContactNameConfirmation(viewModel: viewModel, person: person)
            if person.isRegistered {
                Section("Their Own Name") { Text(verbatim: person.displayName).foregroundStyle(.secondary) }
            }
            StandardContactReplyStatus(viewModel: viewModel, personID: presentationPersonID)
            Section {
                Button("Edit Name") { editsName = true }.accessibilityIdentifier("editContactPersonNameButton")
            }
            if let message = viewModel.contactInvitationMessage {
                Section { Text(LocalizedStringKey(message)).accessibilityIdentifier("contactInvitationMessage") }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            if !person.isRegistered { ContactPersonShareLink(viewModel: viewModel, person: person) }
        }
        .sheet(isPresented: $editsName) { StandardUserSettingsView(viewModel: viewModel, user: person) }
    }
}

/// A reply is status within the saved person's detail/settings, never a second person row.
struct StandardContactReplyStatus: View {
    let viewModel: IntercomViewModel
    let personID: UUID

    var body: some View {
        if let reply = viewModel.contactPersonInvitations(personID).first(where: { $0.direction == .incoming && $0.state == .pending }) {
            Section {
                if viewModel.activeGroupID != nil || viewModel.hasAnyActiveGroupConnection {
                    Text("Waiting for the current call to end.").accessibilityIdentifier("contactInvitationState")
                } else if viewModel.contactInvitationID == reply.id {
                    HStack { ProgressView(); Text("Sending a reply") }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("contactInvitationState")
                } else {
                    Text("Reply not delivered").accessibilityIdentifier("contactInvitationState")
                    Button("Send Again", systemImage: "arrow.clockwise") { _ = viewModel.resumeContactInvitation(reply.id) }
                        .accessibilityIdentifier("retryContactInvitationButton")
                }
            }
        }
    }
}
