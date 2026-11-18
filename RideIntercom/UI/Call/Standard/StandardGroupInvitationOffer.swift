import SwiftUI

/// A Standard-only choice, shown after returning to the list, without interrupting another task.
struct StandardGroupInvitationOffer: ViewModifier {
    let viewModel: IntercomViewModel
    @Binding var selectedTab: AppTab
    let blocked: Bool
    @State private var offered: IntercomGroup?

    private var canPresent: Bool {
        selectedTab == .users && !blocked && viewModel.contactInvitationPresentation == nil
            && !viewModel.needsDisplayNameChoice && viewModel.groupTabInvitationOffer != nil
    }

    func body(content: Content) -> some View {
        content
            .alert("Show the Groups tab?", isPresented: Binding(get: { offered != nil }, set: { if !$0 { offered = nil } }), presenting: offered) { group in
                Button("Show") {
                    if viewModel.acknowledgeGroupTabInvitationOffer(group.id) {
                        viewModel.setShowsGroupsTab(true)
                        selectedTab = .groups
                    }
                }
                Button("Not Now", role: .cancel) { viewModel.acknowledgeGroupTabInvitationOffer(group.id) }
            } message: { group in
                Text("You were invited to \(group.name). Connect from the Groups tab.")
            }
            .onAppear(perform: refresh)
            .onChange(of: canPresent) { _, _ in refresh() }
            .onChange(of: viewModel.contactInvitationRevision) { _, _ in refresh() }
    }

    private func refresh() {
        offered = canPresent ? viewModel.groupTabInvitationOffer : nil
    }
}
