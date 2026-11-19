import SwiftUI

/// Advanced's member row actions: a swipe; a Mac gets the same items on right-click (no long press).
/// The Users and Groups rows share `destinationRowActions` with Standard.
extension View {
    /// Member names are changed from the row's menu or swipe, not a pencil button.
    func advancedMemberRowActions(edit: @escaping () -> Void, canRemove: Bool,
                                  pending: Binding<PendingMemberRemoval?>, name: String,
                                  remove: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingMemberRemoval(name: name, perform: remove) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
        }
        .macRightClickMenu {
            Button(action: edit) { Label("Edit Name", systemImage: "pencil") }
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
    }
}
