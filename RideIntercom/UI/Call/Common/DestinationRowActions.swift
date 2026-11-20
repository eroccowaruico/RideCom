import SwiftUI

/// A Users or Groups row's actions, the same in Standard and Advanced: a swipe, and on a Mac, which cannot
/// swipe with a mouse, the same items on right-click. No long-press menu (it is hard to find).
extension View {
    /// The swipe offers the settings entry, then Delete when the row can be deleted. Delete always
    /// asks first: it only fills `pending`; the list shows the alert (`destinationDeleteConfirmation`).
    func destinationRowActions(_ settingsTitle: LocalizedStringKey, settings: @escaping () -> Void,
                               canDelete: Bool, pending: Binding<PendingDestinationDelete?>,
                               name: String, endsCall: Bool = false,
                               delete: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingDestinationDelete(name: name, endsCall: endsCall, perform: delete) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
        }
        .macRightClickMenu {
            Button(action: settings) { Label(settingsTitle, systemImage: "gearshape") }
            if canDelete {
                Button(role: .destructive, action: ask) { Label("Delete", systemImage: "trash") }
            }
        }
    }
}
