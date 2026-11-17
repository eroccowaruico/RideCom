import Foundation
import Logging

/// Why an invitation link was not taken. The notice shown to the person and the reason written
/// to the log come from this one classification, so they cannot name different causes.
enum InviteRejection: String {
    case expired
    case unsupportedVersion = "unsupported_version"
    case unverified
    case wrongRecipient = "wrong_recipient"
    case incompatibleCall = "incompatible_call"
    case activeGroupKeyChanged = "active_group_key_changed"
    case accountVerificationRequired = "account_verification_required"
    case storageUnavailable = "storage_unavailable"
    case other

    init(_ error: any Error) {
        switch error {
        case GroupInviteTokenError.expired: self = .expired
        case GroupInviteTokenError.unsupportedVersion: self = .unsupportedVersion
        case GroupInviteTokenError.invalidURL, GroupInviteTokenError.invalidTokenEncoding,
             GroupInviteTokenError.invalidSignature: self = .unverified
        case GroupInviteTokenError.wrongRecipient: self = .wrongRecipient
        case GroupInviteTokenError.incompatibleCall: self = .incompatibleCall
        case GroupInviteTokenError.activeGroupKeyChanged: self = .activeGroupKeyChanged
        case GroupInviteTokenError.accountVerificationRequired: self = .accountVerificationRequired
        case IntercomGroupError.storageUnavailable: self = .storageUnavailable
        default: self = .other
        }
    }

    /// The notice when the failing step did not already give its own reason and recovery action.
    var notice: String {
        switch self {
        case .expired: "This invitation has expired. Ask the sender for a new invitation."
        case .unsupportedVersion: "This invitation uses a different app version. Update RideCom and ask for a new invitation."
        case .unverified: "This invitation could not be verified. Ask the sender for a new invitation."
        default: "This invitation could not be opened or saved. Check your account and saved groups, then open the link again."
        }
    }
}

/// Invitation deep-link log metadata. Records only the outcome category, never the token or raw group ID.
enum InviteDeepLinkLog {
    static func accepted(groupID: UUID, kind: IntercomGroup.Kind) -> Logging.Logger.Metadata {
        .event("app.deeplink.invite.accepted", ["groupID": "\(groupID.uuidString)", "kind": "\(kind.rawValue)"])
    }

    static func rejected(_ error: any Error) -> Logging.Logger.Metadata {
        rejected(reason: InviteRejection(error).rawValue)
    }

    static func rejected(reason: String) -> Logging.Logger.Metadata {
        .event("app.deeplink.invite.rejected", ["reason": "\(reason)"])
    }
}
