import SwiftUI

/// Advanced's More menu, named as the implementation's operations: settings, Add Saved Users,
/// and the group invitation (`Invite`, or `Share Call Invite` for a direct group).
struct AdvancedCallMoreMenu: View {
    let viewModel: IntercomViewModel
    @Binding var settings: DestinationSettingsTarget?
    @Binding var addingMembers: IntercomGroup?

    var body: some View {
        if let group = viewModel.selectedGroup {
            let actions: Actions = group.kind == .group
                ? .group(canAddMembers: viewModel.canEditSavedGroups && group.members.count < IntercomGroup.maximumMemberCount)
                : .direct(userID: viewModel.savedUserID(forDirectCall: group))
            let options = Options(groupID: group.id, actions: actions,
                                  shareTitle: viewModel.canShareSelectedGroup ? viewModel.callTitle(for: group) : nil)
            MoreMenu(options: options, viewModel: viewModel, settings: $settings, addingMembers: $addingMembers)
                .equatable()
        }
    }

    private nonisolated enum Actions: Equatable, Sendable {
        case group(canAddMembers: Bool)
        case direct(userID: UUID?)
    }

    private nonisolated struct Options: Equatable, Sendable {
        let groupID: UUID
        let actions: Actions
        let shareTitle: String?
    }

    private struct MoreMenu: View, Equatable {
        let options: Options
        let viewModel: IntercomViewModel
        @Binding var settings: DestinationSettingsTarget?
        @Binding var addingMembers: IntercomGroup?

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.options == rhs.options && lhs.viewModel === rhs.viewModel
        }

        var body: some View {
            // A live group changes on each meter update. Only changes to menu options should
            // replace the open system menu, where that replacement can interrupt a tap.
            Menu {
                switch options.actions {
                case .group(let canAddMembers):
                    Button("Group Settings", systemImage: "gearshape") { settings = .group(options.groupID) }
                        .accessibilityIdentifier("callGroupSettingsButton")
                    Button("Add Saved Users", systemImage: "person.badge.plus") {
                        guard let group = viewModel.selectedGroup, group.id == options.groupID else { return }
                        addingMembers = group
                    }
                    .disabled(!canAddMembers)
                    .accessibilityIdentifier("callAddMembersButton")
                case .direct(let userID):
                    Button("User Settings", systemImage: "gearshape") { settings = userID.map { .user($0) } }
                        .disabled(userID == nil)
                        .accessibilityIdentifier("callUserSettingsButton")
                }
                if let shareTitle = options.shareTitle {
                    CallInvitationButton(invitation: InvitationShare(viewModel: viewModel, groupID: options.groupID),
                                         previewTitle: shareTitle, title: inviteLabel)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("callMoreMenu")
        }

        private var inviteLabel: LocalizedStringKey {
            switch options.actions {
            case .group: "Invite"
            case .direct: "Share Call Invite"
            }
        }
    }
}
