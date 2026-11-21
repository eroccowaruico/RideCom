import SwiftUI

struct AdvancedGroupInvitationSavedView: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    let onDone: () -> Void

    private var people: [UUID] {
        Set(viewModel.groupInvitationPersonIDs(group.id)).union(selectedUsers)
            .sorted { $0.uuidString < $1.uuidString }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(verbatim: group.id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("savedInvitationGroupID")
                } label: { Text(verbatim: "id") }
                LabeledContent {
                    Text(verbatim: group.name).accessibilityIdentifier("savedInvitationGroupName")
                } label: { Text(verbatim: "name") }
            } header: { Text(verbatim: "IntercomGroup") }
            if !people.isEmpty {
                Section {
                    ForEach(people, id: \.self) { personID in
                        if let person = viewModel.contactPerson(personID) {
                            NavigationLink {
                                AdvancedContactPersonDetail(
                                    viewModel: viewModel, person: person, presentationPersonID: personID)
                            } label: {
                                AdvancedRecordRow(
                                    title: person.resolvedDisplayName,
                                    value: "isRegistered \(person.isRegistered)",
                                    detail: "id " + person.id.uuidString.lowercased(),
                                    monospacedDetail: true
                                )
                            }
                            .accessibilityIdentifier("groupInvitePerson-\(personID)")
                        }
                    }
                } header: { Text(verbatim: "SavedUser") }
            }
            if !selectedUsers.isEmpty {
                AdvancedRegisteredGroupInvitations(viewModel: viewModel, group: group, selectedUsers: selectedUsers)
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
