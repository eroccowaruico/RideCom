import SwiftUI

extension View {
    /// A row's swipe items on a Mac's right-click. iPhone and iPad get no long-press menu.
    @ViewBuilder func macRightClickMenu(@ViewBuilder _ items: () -> some View) -> some View {
        #if os(macOS)
        contextMenu { items() }
        #else
        self
        #endif
    }
}
