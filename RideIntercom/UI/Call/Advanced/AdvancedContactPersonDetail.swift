import SwiftUI

struct AdvancedContactPersonDetail: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    let presentationPersonID: UUID
    @State private var editsName = false

    var body: some View {
        Form {
            Section {
                field("id", person.id.uuidString.lowercased())
                field("displayName", person.displayName)
                LabeledContent("localName") {
                    Text(verbatim: person.localName ?? "nil").font(.caption.monospaced())
                        .accessibilityIdentifier("contactPersonSavedName")
                }
                field("memberIDs", person.memberIDs.joined(separator: ", "))
                field("principal", person.principal?.userID ?? "nil")
                Button("User Settings") { editsName = true }
            } header: { Text(verbatim: "SavedUser") }
            ForEach(viewModel.contactPersonInvitations(presentationPersonID)) { record in
                AdvancedContactInvitationContent(viewModel: viewModel, record: record)
            }
            if let message = viewModel.contactInvitationMessage {
                Section { Text(LocalizedStringKey(message)).accessibilityIdentifier("contactInvitationMessage") }
            }
        }
        .formStyle(.grouped)
        .safeAreaBar(edge: .bottom) {
            if !person.isRegistered { ContactPersonShareLink(viewModel: viewModel, person: person) }
        }
        .sheet(isPresented: $editsName) { AdvancedUserSettingsView(viewModel: viewModel, user: person) }
    }

    private func field(_ name: String, _ value: String) -> some View {
        LabeledContent {
            Text(verbatim: value).font(.caption.monospaced()).textSelection(.enabled)
        } label: { Text(verbatim: name).font(.subheadline.monospaced()) }
    }
}
