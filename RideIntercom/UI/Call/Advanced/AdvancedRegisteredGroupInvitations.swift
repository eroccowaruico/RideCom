import SwiftUI

struct AdvancedRegisteredGroupInvitations: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    var body: some View {
        ForEach(viewModel.groupInvitationDeliveries(for: selectedUsers, in: group.id)) { record in
            Section {
                field("id", record.id.uuidString.lowercased())
                field("recipientMemberID", record.recipientMemberID)
                LabeledContent { Text(verbatim: record.state.rawValue).font(.caption.monospaced()).accessibilityIdentifier("groupDeliveryState-\(record.id)") } label: { Text(verbatim: "state") }
                field("expiresAt", String(record.expiresAt))
                field("credentialReference", record.credentialReference?.uuidString.lowercased() ?? "nil")
            } header: { Text(verbatim: "GroupDeliveryRecord") }
        }
        Section {
            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton", bindsToGroup: true)
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent { Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled) } label: { Text(verbatim: title) }
    }
}
