import Foundation

nonisolated struct GroupInvitationAddress: Decodable, Sendable {
    let memberID: String
    let recipientKey: String
}

/// The manifest stores delivery state only. The encrypted packet, when prepared, has an immutable Keychain slot.
nonisolated struct GroupDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    enum Direction: String, Codable, Sendable { case outgoing, incoming }
    enum State: String, Codable, Sendable { case pending, queued, received, cancelled }
    enum InternetAction: Equatable { case send, cancel }

    struct NearbyHandoff: Codable, Equatable, Sendable {
        let envelopeDigest: Data
        var internetCancellationConfirmed = false
    }

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
    var senderMemberID: String?
    var sourceRequestID: UUID?
    var acceptedEnvelopeDigest: Data?
    var nearbyHandoff: NearbyHandoff?

    var internetAction: InternetAction? {
        guard direction == .outgoing else { return nil }
        switch state {
        case .pending, .queued: return .send
        case .cancelled: return nearbyHandoff?.internetCancellationConfirmed == true ? nil : .cancel
        case .received: return nil
        }
    }

    mutating func moveOutgoing(to state: State) {
        self.state = state
        if state == .received || state == .cancelled { credentialReference = nil }
        if state == .received { nearbyHandoff = nil }
    }

    var isValid: Bool {
        sourceRequestID != id && recipient.isValid && IntercomGroup.isValidMemberID(recipientMemberID)
            && !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix)
            && DeviceIdentityProof.isValidPublicKey(recipientKey) && expiresAt.isFinite && expiresAt > 0
            && (direction != .incoming || state != .queued)
            && (direction != .incoming || state != .pending || credentialReference != nil)
            && (direction == .incoming && state == .pending
                ? senderMemberID.map(IntercomGroup.isValidMemberID) == true
                : senderMemberID == nil)
            && (state != .queued || credentialReference != nil)
            && (state != .received && state != .cancelled || credentialReference == nil)
            && (acceptedEnvelopeDigest == nil || (direction == .incoming && state == .received && acceptedEnvelopeDigest?.count == 32))
            && hasValidNearbyHandoff
    }

    private var hasValidNearbyHandoff: Bool {
        guard let nearbyHandoff else { return true }
        return direction == .outgoing && sourceRequestID == nil && nearbyHandoff.envelopeDigest.count == 32
            && state != .received && (state == .cancelled || credentialReference != nil)
            && (!nearbyHandoff.internetCancellationConfirmed || state == .cancelled)
    }
}
