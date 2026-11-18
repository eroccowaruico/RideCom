import Foundation

/// The manifest stores delivery state only. The encrypted packet, when prepared, has an immutable Keychain slot.
nonisolated struct GroupDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    enum Direction: String, Codable, Sendable { case outgoing, incoming }
    enum State: String, Codable, Sendable { case pending, queued, received, cancelled }
    var id: UUID = UUID()
    var noticeID: UUID = UUID()
    var groupID: UUID
    var recipient: AccountPrincipal
    var recipientMemberID: String
    var recipientKey: String
    var expiresAt: TimeInterval
    var direction: Direction = .outgoing
    var state: State = .pending
    var credentialReference: UUID?

    var isValid: Bool {
        recipient.isValid && IntercomGroup.isValidMemberID(recipientMemberID)
            && !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
            && DeviceIdentityProof.isValidPublicKey(recipientKey) && expiresAt.isFinite && expiresAt > 0
            && (direction != .incoming || (state == .received && credentialReference == nil))
            && (state != .queued || credentialReference != nil)
            && (state != .received && state != .cancelled || credentialReference == nil)
    }
}
