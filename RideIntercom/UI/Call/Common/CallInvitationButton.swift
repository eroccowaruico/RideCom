import SwiftUI

/// Both layouts export through the same revalidated invitation operation.
struct CallInvitationButton: View {
    let invitation: InvitationShare
    let previewTitle: String
    let title: LocalizedStringKey
    let accessibilityIdentifier: String

    init(invitation: InvitationShare, previewTitle: String, title: LocalizedStringKey,
         accessibilityIdentifier: String = "inviteButton") {
        self.invitation = invitation
        self.previewTitle = previewTitle
        self.title = title
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    /// Settings and the add-members step share a named group, independent of the selected call.
    init(viewModel: IntercomViewModel, group: IntercomGroup, accessibilityIdentifier: String = "inviteButton",
         titleOverride: LocalizedStringKey? = nil) {
        self.init(invitation: InvitationShare(viewModel: viewModel, settingsGroupID: group.id),
                  previewTitle: viewModel.callTitle(for: group),
                  title: titleOverride ?? (group.kind == .direct ? "Share Call Invite" : "Invite"),
                  accessibilityIdentifier: accessibilityIdentifier)
    }

    var body: some View {
        ShareLink(item: invitation,
                  subject: Text("RideCom Invite"),
                  message: Text("Join me for a call on RideCom."),
                  preview: SharePreview(Text(verbatim: previewTitle))) {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .accessibilityHint("Opens sharing options for this invitation.")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
