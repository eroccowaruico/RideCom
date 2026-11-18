import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Keep secret material out of view evaluation. The system requests the URL
/// when it exports the share item; authorization is checked again at that time.
nonisolated struct InvitationShare: Transferable {
    private let makeURL: @MainActor @Sendable () throws -> URL

    @MainActor
    init(viewModel: IntercomViewModel, groupID: UUID) {
        makeURL = { [weak viewModel] in
            guard let url = viewModel?.makeSelectedGroupInviteURL(expectedGroupID: groupID) else {
                throw CocoaError(.userCancelled)
            }
            return url
        }
    }

    /// Bound to one saved group: Group Settings can share it while another call is shown.
    @MainActor
    init(viewModel: IntercomViewModel, settingsGroupID groupID: UUID) {
        makeURL = { [weak viewModel] in
            guard let url = viewModel?.makeGroupInviteURL(for: groupID) else { throw CocoaError(.userCancelled) }
            return url
        }
    }

    @MainActor
    init(viewModel: IntercomViewModel, contactInvitationID: UUID) {
        let access = viewModel.accountAccessID
        makeURL = { [weak viewModel] in
            guard let viewModel else { throw CocoaError(.userCancelled) }
            return try viewModel.contactInvitationURLForSharing(contactInvitationID, expectedAccountAccessID: access)
        }
    }

    @MainActor
    init(viewModel: IntercomViewModel, contactPersonID: UUID) {
        let access = viewModel.accountAccessID
        makeURL = { [weak viewModel] in
            guard let viewModel else { throw CocoaError(.userCancelled) }
            return try viewModel.contactPersonURLForSharing(contactPersonID, expectedAccountAccessID: access)
        }
    }

    @MainActor
    init(viewModel: IntercomViewModel, contactReplyID: UUID) {
        let access = viewModel.accountAccessID
        makeURL = { [weak viewModel] in
            guard let viewModel else { throw CocoaError(.userCancelled) }
            do { return try viewModel.contactReplyURLForSharing(contactReplyID, expectedAccountAccessID: access) }
            catch {
                viewModel.contactInvitationMessage = "Could not prepare this reply. Try again."
                throw error
            }
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .url) { item in
            let url = try await item.makeURL()
            return try await url.exported(as: .url)
        }
    }
}
