import SwiftUI

extension View {
    /// Reveal the actions with a swipe. On Mac, put the regular action first in the mouse menu.
    func trailingRowActions(
        @ViewBuilder primary: () -> some View,
        @ViewBuilder destructive: () -> some View
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
            destructive()
            primary()
        }
        .macRightClickMenu {
            primary()
            destructive()
        }
    }

    @ViewBuilder private func macRightClickMenu(@ViewBuilder _ items: () -> some View) -> some View {
        #if os(macOS)
        contextMenu { items() }
        #else
        self
        #endif
    }
}
