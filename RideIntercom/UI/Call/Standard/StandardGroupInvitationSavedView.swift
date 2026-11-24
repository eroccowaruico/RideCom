import SwiftUI

struct StandardGroupInvitationSavedView: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    let onDone: () -> Void

    private var people: [UUID] { viewModel.groupInvitationPersonIDs(group.id) }

    var body: some View {
        Form {
            Section {
                Text(verbatim: group.name).font(.headline).accessibilityIdentifier("savedInvitationGroupName")
                if !selectedUsers.isEmpty
                    || people.contains(where: { viewModel.contactPerson($0)?.isRegistered == false }) {
                    Text("Invitations saved. You can close this screen and share them later.")
                        .accessibilityIdentifier("groupDeliverySelectionMessage")
                }
            }
            if !people.isEmpty {
                Section {
                    ForEach(people, id: \.self) { personID in
                        if let person = viewModel.contactPerson(personID) {
                            NavigationLink {
                                StandardContactPersonDetail(
                                    viewModel: viewModel, person: person, presentationPersonID: personID)
                            } label: {
                                HStack {
                                    Text(verbatim: person.resolvedDisplayName)
                                    Spacer()
                                    Text(LocalizedStringKey(person.isRegistered ? "Registered" : "Not registered"))
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("groupInviteRegistrationState-\(personID)")
                                }
                            }
                            .accessibilityIdentifier("groupInvitePerson-\(personID)")
                        }
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
