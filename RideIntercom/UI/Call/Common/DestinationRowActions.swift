import SwiftUI

/// A Users or Groups row's actions, the same in Standard and Advanced: a swipe, and on a Mac, which cannot
/// swipe with a mouse, the same items on right-click. No long-press menu (it is hard to find).
extension View {
    /// The swipe offers the settings entry, then Delete when the row can be deleted. Delete always
    /// asks first: it only fills `pending`; the list shows the alert (`destinationDeleteConfirmation`).
    func destinationRowActions(_ target: DestinationSettingsTarget, name: String, viewModel: IntercomViewModel,
                               settings: Binding<DestinationSettingsTarget?>,
                               pending: Binding<PendingDestinationDelete?>) -> some View {
        let settingsTitle: LocalizedStringKey
        let destination: CallDestination
        let canDelete: Bool
        let delete: () -> Void
        switch target {
        case .group(let id):
            settingsTitle = "Group Settings"
            destination = .group(id)
            canDelete = viewModel.canEditSavedGroups && viewModel.groupRepository.ownsGroup(id)
            delete = { _ = viewModel.deleteGroup(id) }
        case .user(let id):
            settingsTitle = "User Settings"
            destination = .user(id)
            canDelete = viewModel.canEditSavedGroups
            delete = { _ = viewModel.removeSavedUser(id) }
        }
        let endsCall = viewModel.isInCall(with: destination)
        let openSettings = { settings.wrappedValue = target }
        let ask = { pending.wrappedValue = PendingDestinationDelete(name: name, endsCall: endsCall, perform: delete) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
            Button(action: openSettings) { Label(settingsTitle, systemImage: "gearshape") }
        }
        .macRightClickMenu {
            Button(action: openSettings) { Label(settingsTitle, systemImage: "gearshape") }
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }
}
