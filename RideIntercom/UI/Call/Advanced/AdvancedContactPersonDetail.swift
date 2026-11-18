import SwiftUI

struct AdvancedContactPersonDetail: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    let presentationPersonID: UUID
    @State private var editsName = false

    private var currentPerson: SavedUser { viewModel.contactPerson(presentationPersonID) ?? person }

    var body: some View {
        Form {
            Section {
                field("id", currentPerson.id.uuidString.lowercased())
                field("displayName", currentPerson.displayName)
                LabeledContent("localName") {
                    Text(verbatim: currentPerson.localName ?? "nil").font(.caption.monospaced())
                        .accessibilityIdentifier("contactPersonSavedName")
                }
                field("memberIDs", currentPerson.memberIDs.joined(separator: ", "))
                field("principal", currentPerson.principal?.userID ?? "nil")
                Button("User Settings") { editsName = true }.accessibilityIdentifier("editContactPersonNameButton")
            } header: { Text(verbatim: "SavedUser") }
            AdvancedContactNameConfirmation(viewModel: viewModel, person: currentPerson)
            ForEach(viewModel.contactPersonInvitations(presentationPersonID)) { record in
                AdvancedContactInvitationContent(viewModel: viewModel, record: record, personID: presentationPersonID)
            }
            if let message = viewModel.contactInvitationMessage {
                Section { Text(LocalizedStringKey(message)).accessibilityIdentifier("contactInvitationMessage") }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            if !currentPerson.isRegistered { ContactPersonShareButton(viewModel: viewModel, person: currentPerson) }
        }
        .sheet(isPresented: $editsName) { AdvancedUserSettingsView(viewModel: viewModel, user: currentPerson) }
    }

    private func field(_ name: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
        } label: { Text(verbatim: name).font(.subheadline.monospaced()) }
    }
}
