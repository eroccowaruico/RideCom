import SwiftUI

struct StandardGroupInvitationSavedView: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    let onDone: () -> Void

    var body: some View {
        let people = viewModel.groupInvitationPeople(group.id)
        Form {
            Section {
                Text(verbatim: group.name).font(.headline).accessibilityIdentifier("savedInvitationGroupName")
                if !selectedUsers.isEmpty
                    || people.contains(where: { !$0.person.isRegistered }) {
                    Text("Invitations saved. You can close this screen and share them later.")
                        .accessibilityIdentifier("groupDeliverySelectionMessage")
                }
            }
            if !people.isEmpty {
                Section {
                    ForEach(people) { row in
                        NavigationLink {
                            StandardContactPersonDetail(
                                viewModel: viewModel, person: row.person, presentationPersonID: row.id)
                        } label: {
                            HStack {
                                Text(verbatim: row.person.resolvedDisplayName)
                                Spacer()
                                Text(LocalizedStringKey(row.person.isRegistered ? "Registered" : "Not registered"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("groupInviteRegistrationState-\(row.id)")
                            }
                        }
                        .accessibilityIdentifier("groupInvitePerson-\(row.id)")
                    }
                }
            }
            if !selectedUsers.isEmpty {
                StandardRegisteredGroupInvitations(viewModel: viewModel, group: group, selectedUsers: selectedUsers)
            }
        }
        .screenBackground(AppColorPalette.listScreenBackground)
        .navigationTitle("Invitation")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone).accessibilityIdentifier("finishAddingUsersButton")
            }
        }
    }
}
