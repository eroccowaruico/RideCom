import SwiftUI

/// Stored provenance and its actual derived condition, with the two repository operations.
struct AdvancedContactNameConfirmation: View {
    let viewModel: IntercomViewModel
    let person: SavedUser
    var allowsConfirmation = true
    var onResolved: (Bool) -> Void = { _ in }

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: person.usesProvisionalName.map(String.init) ?? "nil").font(.caption.monospaced())
            }
                label: { Text(verbatim: "usesProvisionalName").font(.subheadline.monospaced()) }
            LabeledContent {
                Text(verbatim: String(person.needsNameConfirmation)).font(.caption.monospaced())
                    .accessibilityIdentifier("contactNameConfirmationNeeded")
            } label: { Text(verbatim: "needsNameConfirmation").font(.subheadline.monospaced()) }
            if person.needsNameConfirmation && allowsConfirmation {
                Button("Use Shared Name") {
                    if viewModel.resolveContactPersonName(person, useSharedName: true) { onResolved(true) }
                }
                .disabled(!viewModel.canEditSavedGroups)
                .accessibilityIdentifier("useContactPeerNameButton")
                Button("Keep Local Name") {
                    if viewModel.resolveContactPersonName(person, useSharedName: false) { onResolved(false) }
                }
                    .disabled(!viewModel.canEditSavedGroups)
                    .accessibilityIdentifier("keepContactLocalNameButton")
            }
        } header: { Text(verbatim: "SavedUser name state") }
    }
}
