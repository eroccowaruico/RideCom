import SwiftUI

/// A Users or Groups row's actions, the same in Standard and Advanced: a swipe, and on a Mac, which cannot
/// swipe with a mouse, the same items on right-click. No long-press menu (it is hard to find).
extension View {
    /// Settings is available for every row. Where permitted, Delete opens the list's confirmation.
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
        return trailingRowActions {
            Button(action: openSettings) { Label(settingsTitle, systemImage: "gearshape") }
        } destructive: {
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }
}
