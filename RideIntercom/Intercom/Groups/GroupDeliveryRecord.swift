import Foundation

nonisolated struct GroupInvitationAddress: Decodable, Sendable {
    let memberID: String
    let recipientKey: String
}

/// The manifest stores delivery state only. The encrypted packet, when prepared, has an immutable Keychain slot.
nonisolated struct GroupDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    static let invitationLifetime: TimeInterval = 7 * 86_400
    private static let outcomeWindow: TimeInterval = 28 * 86_400 - invitationLifetime
    enum Direction: String, Codable, Sendable { case outgoing, incoming }
    enum State: String, Codable, Sendable { case pending, queued, received, cancelled }
    enum ExpiredOutcome: String, Codable, Sendable { case awaiting, confirmed }
    enum InternetAction: Equatable { case send, cancel, checkOutcome }
    enum NearbyWork: Hashable { case invitation(UUID), cancellation(UUID) }

    struct NearbyHandoff: Codable, Equatable, Sendable {
        let envelopeDigest: Data
        var internetCancellationConfirmed = false
        var recipientAlreadyReceived: Bool?
    }

    var id = UUID()
    var noticeID = UUID()
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
    var expiredOutcome: ExpiredOutcome?

    var outcomeDeadline: TimeInterval { expiresAt + Self.outcomeWindow }

    var internetAction: InternetAction? {
        guard direction == .outgoing else { return nil }
        if let expiredOutcome { return expiredOutcome == .awaiting ? .checkOutcome : nil }
        switch state {
        case .pending, .queued: return .send
        case .cancelled: return nearbyHandoff?.internetCancellationConfirmed == true ? nil : .cancel
        case .received: return nil
        }
    }

    var nearbyWork: NearbyWork? {
        guard direction == .outgoing, sourceRequestID == nil, expiredOutcome == nil else { return nil }
        switch state {
        case .pending, .queued: return .invitation(id)
        case .cancelled:
            guard let nearbyHandoff, nearbyHandoff.recipientAlreadyReceived != true else { return nil }
            return .cancellation(id)
        case .received: return nil
        }
    }

    mutating func moveOutgoing(to state: State) {
        self.state = state
        if state == .received || state == .cancelled { credentialReference = nil }
        if state == .received { nearbyHandoff = nil }
    }

    func visibleInvitation(at now: TimeInterval) -> Bool {
        expiredOutcome == .confirmed ? now < outcomeDeadline : expiredOutcome == nil && now < expiresAt
    }

    func retainingOutcome(at now: TimeInterval) -> Self? {
        if expiredOutcome != nil { return now < outcomeDeadline ? self : nil }
        if now < expiresAt { return self }
        guard direction == .outgoing, now < outcomeDeadline,
              state == .received || state == .cancelled || credentialReference != nil else { return nil }
        var record = self
        record.expiredOutcome =
            state == .received || nearbyHandoff?.internetCancellationConfirmed == true ? .confirmed : .awaiting
        record.credentialReference = nil
        record.nearbyHandoff = nil
        return record
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
            && (state != .queued || credentialReference != nil || expiredOutcome == .awaiting)
            && (state != .received && state != .cancelled || credentialReference == nil)
            && (acceptedEnvelopeDigest == nil
                || (direction == .incoming && state == .received && acceptedEnvelopeDigest?.count == 32))
            && (expiredOutcome == nil || (direction == .outgoing && credentialReference == nil && nearbyHandoff == nil))
            && (expiredOutcome != .confirmed || state == .received || state == .cancelled)
            && hasValidNearbyHandoff
    }

    private var hasValidNearbyHandoff: Bool {
        guard let nearbyHandoff else { return true }
        return direction == .outgoing && sourceRequestID == nil && nearbyHandoff.envelopeDigest.count == 32
            && state != .received && (state == .cancelled || credentialReference != nil)
            && (!nearbyHandoff.internetCancellationConfirmed || state == .cancelled)
            && (nearbyHandoff.recipientAlreadyReceived == nil
                || (nearbyHandoff.recipientAlreadyReceived == true && state == .cancelled))
    }
}
