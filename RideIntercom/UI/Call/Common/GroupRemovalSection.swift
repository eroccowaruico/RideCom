import SwiftUI

/// The same group removal action and confirmation in both layouts.
struct GroupRemovalSection: View {
    let viewModel: IntercomViewModel
    let group: IntercomGroup
    let onRemoved: () -> Void
    @State private var confirmsRemoval = false

    private var ownsGroup: Bool { viewModel.groupRepository.ownsGroup(group.id) }
    private var endsCall: Bool { viewModel.activeGroupID == group.id || viewModel.isActiveCall(.group(group.id)) }
    private var confirmationTitle: Text {
        ownsGroup ? Text("Delete \(group.name)?") : Text("Leave \(group.name)?")
    }
    private var confirmationAction: LocalizedStringKey {
        switch (ownsGroup, endsCall) {
        case (true, true): "Disconnect and Delete"
        case (true, false): "Delete"
        case (false, true): "Disconnect and Leave"
        case (false, false): "Leave"
        }
    }

    var body: some View {
        Section {
            Button(ownsGroup ? "Delete Group" : "Leave Group", role: .destructive) { confirmsRemoval = true }
                .disabled(!viewModel.canEditSavedGroups)
                .accessibilityIdentifier(ownsGroup ? "deleteGroupButton" : "leaveGroupButton")
        }
        .alert(confirmationTitle, isPresented: $confirmsRemoval) {
            Button(confirmationAction, role: .destructive) {
                viewModel.deleteGroup(group.id)
                onRemoved()
            }
            .accessibilityIdentifier(ownsGroup ? "confirmDeleteGroupButton" : "confirmLeaveGroupButton")
            Button("Cancel", role: .cancel) { }
        } message: {
            if endsCall { Text("The current connection ends.") }
        }
    }
}
