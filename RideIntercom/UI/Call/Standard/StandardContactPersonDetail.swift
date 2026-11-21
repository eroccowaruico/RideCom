import SwiftUI

struct StandardContactPersonDetail: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    let presentationPersonID: UUID
    @State private var editsName = false

    private var currentPerson: SavedUser { viewModel.contactPerson(presentationPersonID) ?? person }

    var body: some View {
        Form {
            Section {
                VStack(spacing: AppSpacing.s) {
                    if currentPerson.isRegistered { DestinationAvatar(isGroup: false, diameter: 56) }
                    else { PendingAvatar(diameter: 56) }
                    Text(verbatim: currentPerson.resolvedDisplayName).font(.title2.bold())
                        .accessibilityIdentifier("contactPersonSavedName")
                    Text(currentPerson.isRegistered ? "Registered" : "Not registered").font(.headline)
                        .accessibilityIdentifier("contactPersonRegistrationState")
                    if !currentPerson.isRegistered {
                        if let invitation = viewModel.contactPersonInvitationForSharing(presentationPersonID) {
                            Text(LocalizedStringKey(viewModel.contactInvitationStateWord(for: invitation)))
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("contactPersonOutgoingInvitationState")
                        }
                        Text("You can call each other after they register.")
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.s)
            }
            StandardContactNameConfirmation(viewModel: viewModel, person: currentPerson)
            if currentPerson.isRegistered {
                Section("Their Own Name") { Text(verbatim: currentPerson.displayName).foregroundStyle(.secondary) }
            }
            if let invitation = viewModel.contactPersonInvitations(presentationPersonID).first(where: { $0.invitedGroupID != nil && $0.state != .cancelled }),
               let group = viewModel.groups.first(where: { $0.id == invitation.invitedGroupID }) {
                Section {
                    if invitation.direction == .incoming { Text("Group saved: \(group.name)") }
                    else { Text("Group invitation: \(group.name)") }
                }
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
            if !currentPerson.isRegistered { ContactPersonShareButton(viewModel: viewModel, person: currentPerson) }
        }
        .sheet(isPresented: $editsName) { StandardUserSettingsView(viewModel: viewModel, user: currentPerson) }
    }
}

/// A reply is status within the saved person's detail/settings, never a second person row.
struct StandardContactReplyStatus: View {
    let viewModel: IntercomViewModel
    let personID: UUID

    var body: some View {
        if let reply = viewModel.contactPersonInvitations(personID).first(where: { $0.direction == .incoming && $0.state == .pending }) {
            Section {
                if reply.hasExpired(at: viewModel.callAccessNow().timeIntervalSince1970) {
                    Text("Reply expired").accessibilityIdentifier("contactInvitationState")
                    Text("Ask the sender for a new invitation.")
                } else if viewModel.contactReplyWaitsForCurrentCall(reply) {
                    Text("Waiting for the current call to end.").accessibilityIdentifier("contactInvitationState")
                } else if viewModel.isTryingContactReply(reply.id) {
                    HStack { ProgressView(); Text("Sending a reply") }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("contactInvitationState")
                } else {
                    Text("Reply not delivered").accessibilityIdentifier("contactInvitationState")
                    Button("Send Again", systemImage: "arrow.clockwise") {
                        _ = viewModel.retryContactPersonInvitation(reply.id, personID: personID)
                    }
                        .disabled(!viewModel.canEditSavedGroups)
                        .accessibilityIdentifier("retryContactInvitationButton")
                }
                if viewModel.canShareContactReply(reply) {
                    ShareLink(item: InvitationShare(viewModel: viewModel, contactReplyID: reply.id),
                        subject: Text("RideCom Reply"), preview: SharePreview(Text("RideCom Reply"))) {
                        Label("Share Reply", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("shareContactReplyButton")
                    Text("Share this reply with \(viewModel.contactInvitationName(for: reply)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        if let confirmation = viewModel.contactPersonInvitations(personID).first(where: {
            $0.direction == .outgoing && $0.receivedBySharing == true && viewModel.canShareContactReply($0)
        }) {
            Section {
                Text("Reply received")
                ShareLink(item: InvitationShare(viewModel: viewModel, contactReplyID: confirmation.id),
                    subject: Text("RideCom Reply"), preview: SharePreview(Text("RideCom Reply"))) {
                    Label("Share Confirmation", systemImage: "square.and.arrow.up")
                }.accessibilityIdentifier("shareContactConfirmationButton")
                Text("They can open this confirmation to clear their pending reply.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
