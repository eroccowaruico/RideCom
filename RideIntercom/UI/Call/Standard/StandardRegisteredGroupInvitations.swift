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
            CallInvitationButton(viewModel: viewModel, group: group, accessibilityIdentifier: "addedUsersInviteButton",
                                 titleOverride: "Share Invitation")
        }
    }
}

/// The same saved invitation state uses the same words wherever it is shown.
struct StandardGroupInvitationStatus: View {
    private let title: LocalizedStringKey

    init(state: GroupDeliveryRecord.State?) {
        title = switch state {
        case .received: "Added to group"
        case .pending, .queued: "Invitation pending"
        case .cancelled: "Invitation stopped"
        case nil: "Sharing required"
        }
    }

    init?(viewModel: IntercomViewModel, memberID: String, groupID: UUID, includeReceived: Bool = true) {
        if let record = viewModel.outgoingGroupInvitation(forPendingMember: memberID, in: groupID) {
            self.init(title: LocalizedStringKey(viewModel.contactInvitationStateWord(for: record)))
        } else if let state = viewModel.groupInvitationDeliveryState(forMember: memberID, in: groupID),
                  includeReceived || state != .received {
            self.init(state: state)
        } else if memberID.hasPrefix(GroupMember.pendingInvitePrefix) {
            self.init(state: .pending)
        } else {
            return nil
        }
    }

    private init(title: LocalizedStringKey) { self.title = title }

    var body: some View { Text(title) }
}
