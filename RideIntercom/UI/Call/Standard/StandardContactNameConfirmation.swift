import SwiftUI

/// Optional naming within the same person's detail. It never gates calling or opens a new sheet.
struct StandardContactNameConfirmation: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    var allowsConfirmation = true
    var onResolved: (Bool) -> Void = { _ in }

    var body: some View {
        if person.needsNameConfirmation && allowsConfirmation, let local = person.localName {
            Section("Choose a Name") {
                Text("Change \(local) to \(person.displayName)?")
                    .accessibilityIdentifier("contactNameQuestion")
                Button("Use Their Name") {
                    if viewModel.resolveContactPersonName(person, useSharedName: true) { onResolved(true) }
                }
                .disabled(!viewModel.canEditSavedGroups)
                .accessibilityIdentifier("useContactPeerNameButton")
                Button("Keep This Name") { if viewModel.resolveContactPersonName(person, useSharedName: false) { onResolved(false) } }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("keepContactLocalNameButton")
            }
        }
    }
}
