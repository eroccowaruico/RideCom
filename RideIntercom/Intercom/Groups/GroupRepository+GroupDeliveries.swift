import Foundation

extension GroupRepository {
    func additionalDeviceDeliverySources(now: TimeInterval) -> [GroupDeliveryRecord] {
        guard let snapshot else { return [] }
        let notices = latestGroupDeliveryNotices(in: snapshot)
        return snapshot.groupDeliveries.filter { record in
            canRedeliver(record, latestNotice: notices[record.groupID]?[record.recipient], now: now, in: snapshot)
        }
    }

    private func canRedeliver(
        _ record: GroupDeliveryRecord, latestNotice: UUID?, now: TimeInterval, in snapshot: GroupSnapshot
    ) -> Bool {
        record.direction == .outgoing && record.sourceRequestID == nil && record.expiredOutcome == nil
            && record.expiresAt > now
            && (record.state == .queued || record.state == .received) && latestNotice == record.noticeID
            && isSelectedGroupDelivery(record, in: snapshot)
    }

    func queueAdditionalDeviceDeliveries(sourceID: UUID, devices: [GroupInvitationAddress], now: TimeInterval)
        throws -> Bool {
        guard !devices.isEmpty, let snapshot,
              let source = snapshot.groupDeliveries.first(where: { $0.id == sourceID }),
            canRedeliver(
                source, latestNotice: latestGroupDeliveryNotices(in: snapshot)[source.groupID]?[source.recipient],
                           now: now, in: snapshot) else { return false }
        let sameInvitation = snapshot.groupDeliveries.filter {
            $0.direction == .outgoing && $0.groupID == source.groupID && $0.recipient == source.recipient
                && $0.noticeID == source.noticeID
        }
        var memberIDs = Set(sameInvitation.map(\.recipientMemberID))
        var keys = Set(sameInvitation.map(\.recipientKey))
        let capacity = GroupSnapshot.maximumGroupDeliveries - snapshot.groupDeliveries.count
        var additions: [GroupDeliveryRecord] = []
        for device in devices where additions.count < capacity {
            let record = GroupDeliveryRecord(
                noticeID: source.noticeID, groupID: source.groupID, recipient: source.recipient,
                recipientMemberID: device.memberID, recipientKey: device.recipientKey, expiresAt: source.expiresAt,
                sourceRequestID: source.id)
            guard !memberIDs.contains(device.memberID), !keys.contains(device.recipientKey), record.isValid,
                  isSelectedGroupDelivery(record, in: snapshot) else { continue }
            additions.append(record)
            memberIDs.insert(device.memberID)
            keys.insert(device.recipientKey)
        }
        guard !additions.isEmpty else { return false }
        try amend(snapshot, now: now) { try self.appendGroupDeliveries(additions, to: &$0) }
        return true
    }

    func saveGroupDeliveryEnvelope(_ envelope: GroupInvitationEnvelope) throws {
        guard let snapshot, let old = snapshot.groupDeliveries.first(where: { $0.id == envelope.id }),
            old.direction == .outgoing, old.expiredOutcome == nil, old.state == .pending,
            old.credentialReference == nil,
              old.recipient == envelope.recipient, old.recipientMemberID == envelope.recipientMemberID,
            old.recipientKey == envelope.recipientKey, old.expiresAt == envelope.expiresAt,
            old.sourceRequestID == envelope.sourceRequestID,
              envelope.senderMemberID == localMemberID else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            guard let index = next.groupDeliveries.firstIndex(where: { $0.id == envelope.id }) else {
                throw GroupStorageError.invalidUpdate
            }
            next.groupDeliveries[index].credentialReference = try self.storeEnvelope(envelope)
        }
    }
    func groupDeliveryEnvelope(_ id: UUID) throws -> GroupInvitationEnvelope {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        return try withCurrentSnapshot(snapshot) {
            guard let record = snapshot.groupDeliveries.first(where: { $0.id == id }),
                record.state == .pending || record.state == .queued,
                  let reference = record.credentialReference, let value = try credentialSecret(reference: reference),
                  let data = value.data(using: .utf8) else { throw GroupStorageError.invalidUpdate }
            let envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: data)
            guard envelope.id == id, envelope.recipient == record.recipient,
                  envelope.recipientKey == record.recipientKey, envelope.recipientMemberID == record.recipientMemberID,
                  envelope.expiresAt == record.expiresAt, envelope.sourceRequestID == record.sourceRequestID
            else { throw GroupStorageError.identityConflict }
            return envelope
        }
    }
    /// Record the exact ciphertext digest before offering it to the local transport.
    func recordNearbyGroupHandoff(_ id: UUID) throws {
        guard let snapshot, let index = snapshot.groupDeliveries.firstIndex(where: { $0.id == id })
        else { throw GroupStorageError.invalidUpdate }
        let record = snapshot.groupDeliveries[index]
        guard record.direction == .outgoing, record.sourceRequestID == nil,
              record.state == .pending || record.state == .queued else { throw GroupStorageError.invalidUpdate }
        guard record.nearbyHandoff == nil else { return }
        let digest = try groupDeliveryEnvelope(id).receiptDigest()
        try amend(snapshot) { next in
            next.groupDeliveries[index].nearbyHandoff = .init(envelopeDigest: digest)
        }
    }

    func setGroupDeliveryState(_ id: UUID, state: GroupDeliveryRecord.State) throws {
        guard let snapshot, let old = snapshot.groupDeliveries.first(where: { $0.id == id }),
            old.direction == .outgoing,
              old.expiredOutcome == nil, old.state == .pending || old.state == .queued, state != .pending,
              state != .queued || old.credentialReference != nil else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            guard let index = next.groupDeliveries.firstIndex(where: { $0.id == id }) else {
                throw GroupStorageError.invalidUpdate
            }
            next.groupDeliveries[index].moveOutgoing(to: state)
        }
    }
    func confirmNearbyGroupCancellation(
        _ id: UUID, outcome: GroupInvitationCancellationReceipt.Outcome, now: TimeInterval
    ) throws {
        guard let snapshot, let index = snapshot.groupDeliveries.firstIndex(where: { $0.id == id }),
              snapshot.groupDeliveries[index].nearbyWork == .cancellation(id),
              snapshot.groupDeliveries[index].expiresAt > now else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot, now: now) { next in
            switch outcome {
            case .cancelled:
                if next.groupDeliveries[index].nearbyHandoff?.internetCancellationConfirmed == true {
                    next.groupDeliveries.remove(at: index)
                } else {
                    next.groupDeliveries[index].nearbyHandoff = nil
                }
            case .alreadyReceived:
                next.groupDeliveries[index].nearbyHandoff?.recipientAlreadyReceived = true
            }
        }
    }

    func removeFinishedGroupDeliveries(now: TimeInterval, internetCancelledID: UUID? = nil) throws {
        guard let snapshot else { throw IntercomGroupError.storageUnavailable }
        var deliveries = snapshot.groupDeliveries
        if let confirmed = deliveries.firstIndex(where: {
            $0.id == internetCancelledID && $0.internetAction == .cancel
        }) {
            if deliveries[confirmed].nearbyHandoff != nil {
                deliveries[confirmed].nearbyHandoff?.internetCancellationConfirmed = true
            } else {
                deliveries.remove(at: confirmed)
            }
        }
        deliveries = deliveries.compactMap { $0.retainingOutcome(at: now) }
        guard deliveries != snapshot.groupDeliveries
                || snapshot.nearbyGroupCancellations.contains(where: { $0.expiresAt <= now }) else { return }
        try amend(snapshot, now: now) { $0.groupDeliveries = deliveries }
    }

    func confirmExpiredGroupDeliveryOutcome(_ id: UUID, state: GroupDeliveryRecord.State?, now: TimeInterval) throws {
        guard let snapshot, let index = snapshot.groupDeliveries.firstIndex(where: { $0.id == id }),
              snapshot.groupDeliveries[index].expiredOutcome == .awaiting else { return }
        try amend(snapshot, now: now) { next in
            if let state, state == .received || state == .cancelled, next.groupDeliveries[index].outcomeDeadline > now {
                next.groupDeliveries[index].moveOutgoing(to: state)
                next.groupDeliveries[index].expiredOutcome = .confirmed
            } else {
                next.groupDeliveries.remove(at: index)
            }
        }
    }

    static func cancelPendingGroupReceipts(
        in next: inout GroupSnapshot, matching: (GroupDeliveryRecord) -> Bool
    ) {
        for index in next.groupDeliveries.indices {
            let record = next.groupDeliveries[index]
            guard record.direction == .incoming, record.state == .pending, matching(record) else { continue }
            next.groupDeliveries[index].state = .cancelled
            next.groupDeliveries[index].credentialReference = nil
            next.groupDeliveries[index].senderMemberID = nil
        }
    }

    func cancelPendingGroupReceipt(_ id: UUID) throws {
        guard let snapshot,
            snapshot.groupDeliveries.contains(where: {
                $0.id == id && $0.direction == .incoming && $0.state == .pending
            })
        else { return }
        try amend(snapshot) { next in Self.cancelPendingGroupReceipts(in: &next) { $0.id == id } }
    }

    func rememberNearbyGroupCancellation(_ target: GroupInvitationCancellation.Target, now: TimeInterval)
        throws -> GroupInvitationCancellationReceipt.Outcome {
        guard let snapshot = writableSnapshot, target.isValid, target.expiresAt > now,
            target.recipientMemberID == localMemberID
        else { throw GroupStorageError.invalidUpdate }
        let existing = snapshot.groupDeliveries.first {
            $0.id == target.id && $0.direction == .incoming && $0.sourceRequestID == nil && $0.groupID == target.groupID
                && $0.recipient == target.recipient && $0.recipientMemberID == target.recipientMemberID
                && $0.recipientKey == target.recipientKey && $0.expiresAt == target.expiresAt
        }
        let alreadyReceived = existing?.state == .received && existing?.acceptedEnvelopeDigest == target.envelopeDigest
        if alreadyReceived || snapshot.nearbyGroupCancellations.contains(target) {
            return try withCurrentSnapshot(snapshot) { alreadyReceived ? .alreadyReceived : .cancelled }
        }

        var cancelStaged = false
        if existing?.state == .pending && existing?.senderMemberID == target.senderMemberID {
            let envelope = try groupDeliveryEnvelope(target.id)
            cancelStaged = try GroupInvitationCancellation.Target(envelope: envelope, groupID: target.groupID) == target
        }
        try amend(snapshot, now: now) { next in
            next.nearbyGroupCancellations.append(target)
            if cancelStaged { Self.cancelPendingGroupReceipts(in: &next) { $0.id == target.id } }
        }
        return .cancelled
    }

    private func isCancelledNearby(_ envelope: GroupInvitationEnvelope, groupID: UUID, now: TimeInterval,
                                   in snapshot: GroupSnapshot) throws -> Bool {
        guard envelope.sourceRequestID == nil, envelope.expiresAt > now,
              snapshot.nearbyGroupCancellations.contains(where: { $0.id == envelope.id }) else { return false }
        return snapshot.nearbyGroupCancellations.contains(
            try GroupInvitationCancellation.Target(envelope: envelope, groupID: groupID))
    }

    func stageGroupDelivery(_ envelope: GroupInvitationEnvelope, token: GroupInviteToken, now: TimeInterval,
                            redeliveryTrust: DeviceIdentityTrust? = nil) throws -> GroupDeliveryRecord.State {
        let verified = try validateIncomingGroupDelivery(
            envelope, token: token, now: now, redeliveryTrust: redeliveryTrust)
        let snapshot = verified.snapshot
        if try isCancelledNearby(envelope, groupID: token.groupID, now: now, in: snapshot) { return .cancelled }
        let old = snapshot.groupDeliveries.first(where: { $0.id == envelope.id })
        if let old {
            guard old.direction == .incoming, old.groupID == token.groupID, old.recipient == envelope.recipient,
                  old.recipientMemberID == envelope.recipientMemberID, old.recipientKey == envelope.recipientKey,
                  old.expiresAt == envelope.expiresAt, old.sourceRequestID == envelope.sourceRequestID
            else { throw GroupStorageError.identityConflict }
            if old.state != .pending { return old.state }
        }
        let target = ContactGroupInvitation(id: token.groupID, name: token.groupName, secret: token.groupSecret)
        let existing = snapshot.groups.first(where: { $0.id == token.groupID })
        if let existing, try !matchesGroupDelivery(
            target, sender: verified.identity, principal: envelope.sender, existing: existing
        ) {
            if old != nil { try cancelPendingGroupReceipt(envelope.id) }
            return .cancelled
        }
        if old != nil { return .pending }
        guard existing != nil || snapshot.groups.count < 256 else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            next.groupDeliveries.append(.init(id: envelope.id, noticeID: envelope.id, groupID: token.groupID,
                    recipient: envelope.recipient, recipientMemberID: envelope.recipientMemberID,
                    recipientKey: envelope.recipientKey,
                expiresAt: envelope.expiresAt, direction: .incoming, state: .pending,
                    credentialReference: try self.storeEnvelope(envelope), senderMemberID: envelope.senderMemberID,
                    sourceRequestID: envelope.sourceRequestID))
        }
        return .pending
    }

    @discardableResult
    func receiveGroupDelivery(
        _ envelope: GroupInvitationEnvelope, token: GroupInviteToken, localDisplayName: String, now: TimeInterval,
        redeliveryTrust: DeviceIdentityTrust? = nil, fromNearby: Bool = false
    ) throws -> IntercomGroup? {
        guard let snapshot, !fromNearby || envelope.sourceRequestID == nil else {
            throw GroupStorageError.invalidUpdate
        }
        if try isCancelledNearby(envelope, groupID: token.groupID, now: now, in: snapshot) { return nil }
        let index = snapshot.groupDeliveries.firstIndex(where: { $0.id == envelope.id })
        if let index {
            guard try matchesPendingGroupReceipt(
                snapshot.groupDeliveries[index], envelope: envelope, groupID: token.groupID, fromNearby: fromNearby
            ) else { return nil }
        } else if !fromNearby {
            throw GroupStorageError.invalidUpdate
        }
        let verified = try validateIncomingGroupDelivery(
            envelope, token: token, now: now, redeliveryTrust: redeliveryTrust)
        guard let localMemberID else { throw GroupStorageError.invalidUpdate }
        let target = ContactGroupInvitation(id: token.groupID, name: token.groupName, secret: token.groupSecret)
        let existing = snapshot.groups.first(where: { $0.id == target.id })
        if let existing, try !matchesGroupDelivery(
            target, sender: verified.identity, principal: envelope.sender, existing: existing
        ) {
            // A manual join, local save or removal can race with the Worker receipt.
            try cancelPendingGroupReceipt(envelope.id)
            return nil
        }
        let previous = try snapshot.groups.map { try $0.group() }
        let newGroup = existing == nil
        let groups =
            newGroup
            ? try groupsByJoining(
                target, inviter: .init(id: envelope.senderMemberID, displayName: verified.inviterName),
            identity: verified.identity, localDisplayName: localDisplayName, groups: previous) : previous
        let digest = try envelope.receiptDigest()
        let credential = newGroup ? GroupAccessCredential(groupID: token.groupID, secret: token.groupSecret) : nil
        try update(groups, credential: credential) { next in
            if let groupIndex = next.groups.firstIndex(where: { $0.id == token.groupID }) {
                if newGroup {
                    next.groups[groupIndex].joinedByInvitation = true
                    next.groups[groupIndex].groupTabOfferAcknowledged = false
                    next.groups[groupIndex].accountDevices[localMemberID] = .init(
                        principal: envelope.recipient, publicKey: envelope.recipientKey)
                    next.groups[groupIndex].accountDevices[envelope.senderMemberID] = .init(
                        principal: envelope.sender, publicKey: verified.identity.publicKey)
                }
                try next.groups[groupIndex].rememberInvitationDevice(verified.identity)
            }
            self.storeReceivedGroupDelivery(
                envelope, groupID: token.groupID, digest: digest, replacing: index, in: &next
            )
        }
        return storedGroup(token.groupID)
    }

    private func matchesPendingGroupReceipt(
        _ record: GroupDeliveryRecord, envelope: GroupInvitationEnvelope, groupID: UUID, fromNearby: Bool
    ) throws -> Bool {
        guard record.direction == .incoming else { throw GroupStorageError.invalidUpdate }
        // A deletion can cancel a staged record before the Internet acknowledgement returns.
        guard record.state == .pending else { return false }
        guard record.groupID == groupID, record.recipient == envelope.recipient,
              record.recipientMemberID == envelope.recipientMemberID, record.recipientKey == envelope.recipientKey,
              record.senderMemberID == envelope.senderMemberID, record.expiresAt == envelope.expiresAt,
              record.sourceRequestID == envelope.sourceRequestID
        else { throw GroupStorageError.invalidUpdate }
        if fromNearby, try groupDeliveryEnvelope(envelope.id).receiptDigest() != envelope.receiptDigest() {
            throw GroupStorageError.invalidUpdate
        }
        return true
    }

    private func storeReceivedGroupDelivery(
        _ envelope: GroupInvitationEnvelope, groupID: UUID, digest: Data, replacing index: Int?,
        in next: inout GroupSnapshot
    ) {
        if let index {
            next.groupDeliveries[index].state = .received
            next.groupDeliveries[index].credentialReference = nil
            next.groupDeliveries[index].senderMemberID = nil
            next.groupDeliveries[index].acceptedEnvelopeDigest = digest
        } else {
            next.groupDeliveries.append(.init(id: envelope.id, noticeID: envelope.id, groupID: groupID,
                    recipient: envelope.recipient, recipientMemberID: envelope.recipientMemberID,
                    recipientKey: envelope.recipientKey,
                    expiresAt: envelope.expiresAt, direction: .incoming, state: .received,
                    acceptedEnvelopeDigest: digest))
        }
    }

    private struct VerifiedGroupDelivery {
        let inviterName: String
        let identity: VerifiedDeviceProof
        let snapshot: GroupSnapshot
    }

    private func validateIncomingGroupDelivery(
        _ envelope: GroupInvitationEnvelope, token: GroupInviteToken,
        now: TimeInterval, redeliveryTrust: DeviceIdentityTrust?
    ) throws -> VerifiedGroupDelivery {
        try token.validate()
        guard let snapshot, envelope.expiresAt > now, token.expiresAt == envelope.expiresAt,
              token.verifySignature(), token.inviterMemberID == envelope.senderMemberID,
              token.recipientMemberID == nil, token.directInvitation?.context.contactBootstrap != true,
              let proof = token.identityProof, proof.publicKey == envelope.proof?.publicKey,
            token.groupID
                != IntercomGroup.directCallID(memberIDs: [envelope.senderMemberID, envelope.recipientMemberID]),
            let localMemberID, localMemberID == envelope.recipientMemberID
        else { throw GroupStorageError.invalidUpdate }
        if envelope.sourceRequestID != nil {
            guard let redeliveryTrust else { throw GroupStorageError.invalidUpdate }
            let identity = try token.verifyInviterProof(trust: redeliveryTrust, now: Date(timeIntervalSince1970: now))
            guard identity.principal == envelope.sender else { throw GroupStorageError.invalidUpdate }
            return .init(inviterName: inviterName(for: token), identity: identity, snapshot: snapshot)
        }
        guard
            let user = snapshot.users.first(where: {
                $0.principal == envelope.sender && $0.memberIDs.contains(envelope.senderMemberID)
                    && $0.deviceKeys?[envelope.senderMemberID] == envelope.proof?.publicKey
            })
        else { throw GroupStorageError.invalidUpdate }
        let identity = try token.verifyInviterProof()
        return .init(inviterName: user.displayName, identity: identity, snapshot: snapshot)
    }

    private func matchesGroupDelivery(_ target: ContactGroupInvitation, sender: VerifiedDeviceProof,
                                      principal: AccountPrincipal, existing: GroupSnapshot.Record) throws -> Bool {
        guard !existing.excludesMember(sender.memberID, principal: principal),
              existing.matchesInvitationDeviceKey(sender.publicKey, for: sender.memberID),
            existing.accountDevices[sender.memberID].map({ $0.publicKey == sender.publicKey }) ?? true
        else { return false }
        return try matchesSavedGroup(target, kind: existing.kind ?? .group)
    }

    private func storeEnvelope(_ envelope: GroupInvitationEnvelope) throws -> UUID {
        let data = try JSONEncoder().encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else { throw GroupStorageError.invalidUpdate }
        return try prepareKey(text)
    }
}
