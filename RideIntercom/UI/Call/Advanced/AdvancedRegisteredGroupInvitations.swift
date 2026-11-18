import SwiftUI

struct AdvancedRegisteredGroupInvitations: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    var body: some View {
        AdvancedGroupDeliveryRecords(records: viewModel.groupInvitationDeliveries(for: selectedUsers, in: group.id))
        Section {
            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton")
        }
    }
}

/// Advanced shows these same stored fields after closing the saved invitation sheet.
struct AdvancedGroupDeliveryRecords: View {
    let records: [GroupDeliveryRecord]
    var body: some View {
        ForEach(records) { record in
            Section {
                field("id", record.id.uuidString.lowercased())
                field("recipientMemberID", record.recipientMemberID)
                LabeledContent { Text(verbatim: record.state.rawValue).font(.caption.monospaced()).accessibilityIdentifier("groupDeliveryState-\(record.id)") } label: { Text(verbatim: "state") }
                field("expiresAt", String(record.expiresAt))
                field("credentialReference", record.credentialReference?.uuidString.lowercased() ?? "nil")
            } header: { Text(verbatim: "GroupDeliveryRecord") }
        }
    }
    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent { Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled) } label: { Text(verbatim: title) }
    }
}
