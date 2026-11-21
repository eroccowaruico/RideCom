import Foundation

struct ContactInvitationPreview: Equatable, Identifiable {
    let id: UUID
    let inviterName: String
    let expiresAt: TimeInterval
    let accountAccessID: UUID
    let url: URL
    var invitedGroupName: String?
}

enum ContactInvitationPresentation: Equatable, Identifiable {
    case person(UUID)
    case sharing(UUID)
    case accepting(ContactInvitationPreview)

    var id: String {
        switch self {
        case .person(let id): "person-" + id.uuidString
        case .sharing(let id): "share-" + id.uuidString
        case .accepting(let preview): "accept-" + preview.id.uuidString
        }
    }
}
