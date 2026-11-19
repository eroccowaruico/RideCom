import SwiftUI

/// Standard's member row action: a swipe removes them. A Mac, which cannot swipe with a mouse, gets it on
/// right-click. The Users and Groups rows share `destinationRowActions` with Advanced.
extension View {
    /// A group member's swipe removes them (asks first); the row's tap opens the member's own page.
    func standardMemberRowActions(canRemove: Bool, pending: Binding<PendingMemberRemoval?>, name: String,
                                  remove: @escaping () -> Void) -> some View {
        let ask = { pending.wrappedValue = PendingMemberRemoval(name: name, perform: remove) }
        return swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
        .macRightClickMenu {
            if canRemove { Button(role: .destructive, action: ask) { Label("Remove", systemImage: "person.badge.minus") } }
        }
    }
}
