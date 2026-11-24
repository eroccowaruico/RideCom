import SwiftUI

struct AdvancedGroupInvitationSavedView: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let selectedUsers: Set<UUID>
    let onDone: () -> Void

    var body: some View {
        let people = viewModel.groupInvitationPeople(group.id, including: selectedUsers)
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
                    ForEach(people) { row in
                        NavigationLink {
                            AdvancedContactPersonDetail(
                                viewModel: viewModel, person: row.person, presentationPersonID: row.id)
                        } label: {
                            AdvancedRecordRow(
                                title: row.person.resolvedDisplayName,
                                value: "isRegistered \(row.person.isRegistered)",
                                detail: "id " + row.person.id.uuidString.lowercased(),
                                monospacedDetail: true
                            )
                        }
                        .accessibilityIdentifier("groupInvitePerson-\(row.id)")
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
