import SwiftUI

struct StandardRegisteredGroupInvitations: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    var body: some View {
        Section {
            Text("Invitations saved. You can check each person's status and share an invitation if needed.")
                .accessibilityIdentifier("groupDeliverySelectionMessage")
            ForEach(viewModel.savedRemoteUsers.filter { selectedUsers.contains($0.id) }) { person in
                LabeledContent { StandardGroupInvitationStatus(state: viewModel.groupInvitationDeliveryState(for: person, in: group.id)) } label: { Text(verbatim: person.resolvedDisplayName) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("groupDeliveryPerson-\(person.id)")
            }
            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton", bindsToGroup: true, titleOverride: "Share Invitation")
        }
    }
}

/// The same saved delivery state has the same words in selection and group settings.
struct StandardGroupInvitationStatus: View {
    let state: GroupDeliveryRecord.State?
    var body: some View { Text(title) }
    private var title: LocalizedStringKey {
        switch state {
        case .received: "Added to group"
        case .pending, .queued: "Invitation pending"
        case .cancelled: "Invitation stopped"
        case nil: "Sharing required"
        }
    }
}
