import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var owner: AppCallOwner
    @State private var pendingInviteURL: URL?
    @State private var selectedTab: AppTab = .users

    var body: some View {
        Group {
            if owner.account.deletion.blocksSignIn {
                AccountDeletionProgressView(account: owner.account)
            } else if let viewModel = owner.viewModel, viewModel.hasCurrentAccountAccess {
                if viewModel.requiresAccountDataReset {
                    AccountDataResetView(viewModel: viewModel)
                } else {
                    SignedInContentView(viewModel: viewModel, selectedTab: $selectedTab)
                }
            } else {
                AppleSignInView(account: owner.account, hasPendingInvite: pendingInviteURL != nil)
            }
        }
        .onChange(of: owner.callPresentationID) { _, _ in selectedTab = .call }
        .onChange(of: owner.usersPresentationID) { _, _ in selectedTab = .users }
        .onChange(of: owner.groupsPresentationID) { _, _ in
            selectedTab = owner.viewModel?.isGroupsTabVisible == true ? .groups : .users
        }
        .task { await owner.refreshAccountForForeground() }
        // The OS asks once, at the first launch; afterwards this returns the choice without asking.
        .task {
            if (try? await NotificationSystem.requestAuthorization()) == true {
                await owner.viewModel?.startNotifications()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await owner.refreshAccountForForeground() } }
            if phase == .background { owner.viewModel?.suspendContactInvitationForBackground() }
        }
        .onChange(of: owner.viewModel?.accountAccessID) { previous, _ in
            if previous != nil { pendingInviteURL = nil }
            if let viewModel = owner.viewModel, let pendingInviteURL {
                openInvitation(pendingInviteURL, in: viewModel)
                self.pendingInviteURL = nil
            }
        }
        .onOpenURL { url in
            if url.scheme == "rideintercom", url.host == "call" { selectedTab = .call; return }
            guard !owner.account.deletion.blocksSignIn, url.scheme == "rideintercom",
                url.host == "join" || url.host == "contact" || url.host == "contact-reply"
            else { return }
            if let viewModel = owner.viewModel, viewModel.canStartCalls {
                openInvitation(url, in: viewModel)
            } else {
                pendingInviteURL = url
            }
        }
    }

    private func openInvitation(_ url: URL, in viewModel: IntercomViewModel) {
        if url.host == "contact-reply" {
            selectedTab = .users
            _ = viewModel.handleContactReplyURL(url)
            return
        }
        if url.host == "contact" {
            selectedTab = .users
            _ = viewModel.previewContactInvitation(url)
            return
        }
        selectedTab = .call
        // The common operation preserves the reason and recovery action for every entry point.
        try? viewModel.acceptInviteURL(url)
    }
}

#Preview {
    ContentView(owner: AppCallOwner(account: .makeForCurrentProcess(), viewModel: nil))
}
