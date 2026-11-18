import SwiftUI

/// `ContactInvitationRecord` as stored, one record per row, at the end of Users.
struct AdvancedInvitationsSection: View {
    let viewModel: IntercomViewModel

    var body: some View {
        let records = viewModel.unlinkedContactInvitations
        if !records.isEmpty {
            Section {
                ForEach(records) { record in
                    Button { viewModel.showContactInvitation(record.id) } label: { AdvancedInvitationRow(record: record) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("pendingContactInvitation-\(record.id)")
                }
            } header: {
                Text(verbatim: "Invitations \(records.count)")
            }
        }
        if let message = viewModel.contactInvitationMessage {
            Section {
                Text(LocalizedStringKey(message))
                    .accessibilityIdentifier("contactInvitationMessage")
            }
        }
    }
}

private struct AdvancedInvitationRow: View {
    let record: ContactInvitationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: String(record.id.uuidString.prefix(8)).lowercased())
                .font(.headline.monospaced()).foregroundStyle(Color.primary)
            Text(verbatim: "\(record.direction.rawValue) · \(record.state.rawValue)\(record.canResume ? " · canResume" : "")")
                .font(.subheadline.monospaced()).foregroundStyle(Color.primary)
            Text(verbatim: "expiresAt \(Date(timeIntervalSince1970: record.expiresAt).formatted(.iso8601))")
                .font(.caption.monospaced()).foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The stored record, the notification session and the implementation's operations under its conditions.
struct AdvancedContactInvitationDetail: View {
    let viewModel: IntercomViewModel
    let record: ContactInvitationRecord
    var body: some View {
        Form { AdvancedContactInvitationContent(viewModel: viewModel, record: record) }.formStyle(.grouped)
    }
}

struct AdvancedContactInvitationContent: View {
    let viewModel: IntercomViewModel
    let record: ContactInvitationRecord
    var personID: UUID? = nil
    @State private var confirmsCancellation = false

    private var stopsRetrying: Bool { record.direction == .incoming || record.state == .confirmed }

    var body: some View {
        Group {
            Section {
                field("id", record.id.uuidString.lowercased())
                field("personID", record.personID?.uuidString.lowercased() ?? "nil")
                field("direction", record.direction.rawValue)
                field("state", record.state.rawValue)
                field("canResume", String(record.canResume))
                field("hasExpired", String(record.hasExpired(at: viewModel.callAccessNow().timeIntervalSince1970)))
                field("receivedBySharing", record.receivedBySharing.map(String.init) ?? "nil")
                field("expiresAt", Date(timeIntervalSince1970: record.expiresAt).formatted(.iso8601))
                field("peerMemberID", record.peerMemberID ?? "nil")
                field("nickname", record.nickname ?? "nil")
                field("session", viewModel.contactInvitationID == record.id ? "running" : "stopped")
            } header: {
                Text(verbatim: "ContactInvitationRecord")
            }
            Section {
                Text(LocalizedStringKey(viewModel.contactInvitationStatus(for: record)))
                    .accessibilityIdentifier("contactInvitationStatus")
                if let message = viewModel.contactInvitationMessage { Text(LocalizedStringKey(message)) }
            }
            Section {
                if record.personID == nil && record.direction == .outgoing && record.state == .pending {
                    ShareLink(item: InvitationShare(viewModel: viewModel, contactInvitationID: record.id),
                              subject: Text("RideCom Invite"), preview: SharePreview(Text("RideCom Invite"))) {
                        Label("Share Again", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("shareContactInvitationButton")
                }
                if viewModel.canShareContactReply(record) {
                    ShareLink(item: InvitationShare(viewModel: viewModel, contactReplyID: record.id),
                        subject: Text("RideCom Reply"), preview: SharePreview(Text("RideCom Reply"))) {
                        Label(record.direction == .incoming ? "Share Accepted Receipt" : "Share Acknowledgement", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier(record.direction == .incoming ? "shareContactReplyButton" : "shareContactConfirmationButton")
                }
                if record.canResume && !record.hasExpired(at: viewModel.callAccessNow().timeIntervalSince1970) {
                    Button("Retry Notification", systemImage: "arrow.clockwise") {
                        if let personID {
                            _ = viewModel.retryContactPersonInvitation(record.id, personID: personID)
                        } else { viewModel.retryPresentedContactInvitation(record.id) }
                    }
                    .disabled(!viewModel.canEditSavedGroups || viewModel.activeGroupID != nil || viewModel.hasAnyActiveGroupConnection)
                    .accessibilityIdentifier("retryContactInvitationButton")
                    Button(stopsRetrying ? "Stop Retrying Notification" : "Cancel Pending Invitation", role: .destructive) {
                        confirmsCancellation = true
                    }
                    .accessibilityIdentifier("cancelPendingContactInvitationButton")
                }
            }
        }
        .alert(stopsRetrying ? "Stop Retrying Notification?" : "Cancel This Pending Invitation?", isPresented: $confirmsCancellation) {
            Button(stopsRetrying ? "Stop Retrying Notification" : "Cancel Pending Invitation", role: .destructive) {
                if let personID {
                    _ = viewModel.cancelContactPersonInvitation(record.id, personID: personID)
                } else { _ = viewModel.cancelPresentedContactInvitation(record.id) }
            }
            .accessibilityIdentifier("confirmCancelContactInvitationButton")
            Button("Keep Pending Invitation", role: .cancel) {}
        } message: {
            if record.direction == .incoming {
                Text("Stops retries on this device. The saved contact remains.")
            } else {
                Text("Stops retries on this device. A link already shared may still be accepted until it expires.")
            }
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("contactInvitationField-\(name)")
        } label: {
            Text(verbatim: name).font(.subheadline.monospaced())
        }
    }
}
