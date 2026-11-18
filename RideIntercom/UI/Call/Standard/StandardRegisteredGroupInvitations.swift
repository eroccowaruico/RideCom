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
                LabeledContent { Text(status(person)) } label: { Text(verbatim: person.resolvedDisplayName) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("groupDeliveryPerson-\(person.id)")
            }
            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton", bindsToGroup: true, titleOverride: "Share Invitation")
        }
    }
    private func status(_ person: SavedUser) -> LocalizedStringKey {
        switch viewModel.groupInvitationDeliveryState(for: person, in: group.id) {
        case .received: "Added to group"
        case .pending, .queued: "Invitation pending"
        case .cancelled: "Invitation stopped"
        case nil: "Sharing required"
        }
    }
}
