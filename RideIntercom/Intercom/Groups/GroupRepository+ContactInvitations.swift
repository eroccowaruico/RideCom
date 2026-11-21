import CryptoKit
import Foundation

extension GroupRepository {
    func stageContactInvitation(
        _ token: GroupInviteToken, now: TimeInterval, replacingExpiredInvitation id: UUID? = nil,
        personID: UUID? = nil
    ) throws {
        try token.validate(contactBootstrap: true)
        guard now.isFinite, let snapshot, let context = token.directInvitation?.context,
              token.inviterMemberID == localMemberID, !token.isExpired(now: now), token.verifySignature(),
            !snapshot.contactInvitations.contains(where: { $0.id == context.id })
        else { throw GroupStorageError.invalidUpdate }
        guard let proof = token.identityProof else { throw GroupStorageError.invalidUpdate }
        _ = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: token.inviterMemberID)
        let previous = id.flatMap { id in snapshot.contactInvitations.first { $0.id == id } }
        if id != nil {
            guard let previous, previous.isExpiredOutgoing(at: now) else {
                throw GroupStorageError.invalidUpdate
            }
        }
        let personID = personID ?? previous?.personID
        if let personID {
            guard snapshot.users.contains(where: { $0.id == personID && !$0.isRegistered }) else {
                throw GroupStorageError.invalidUpdate
            }
            guard
                !snapshot.contactInvitations.contains(where: {
                    $0.personID == personID && $0.id != id && $0.state == .pending && $0.expiresAt > now
                })
            else {
                throw GroupStorageError.invalidUpdate
            }
        }
        if let target = token.invitedGroup {
            guard personID != nil, let group = snapshot.groups.first(where: { $0.id == target.id }),
                group.kind == .group,
                  group.members.contains(where: { $0.id == localMemberID }),
                  try credential(for: target.id)?.secret == target.secret else { throw GroupStorageError.invalidUpdate }
        }
        let payload = ContactInvitationPayload(token: token)
        try amend(snapshot) { next in
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
            // The old record, its name and the new credential change at the manifest's sole commit point.
            if let id { next.contactInvitations.removeAll { $0.id == id } }
            let reference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations.append(.init(id: context.id, direction: .outgoing,
                    expiresAt: context.expiresAt, credentialReference: reference,
                    nickname: previous?.nickname
                        ?? snapshot.users.first(where: { $0.id == personID })?.resolvedDisplayName, sent: false,
                    personID: personID, invitedGroupID: token.invitedGroup?.id))
            try Self.reserveContactInvitationSlot(for: token.invitedGroup, replacing: previous, in: &next)
        }
    }

    private static func reserveContactInvitationSlot(
        for target: ContactGroupInvitation?, replacing previous: ContactInvitationRecord?, in next: inout GroupSnapshot
    ) throws {
        if let target = target, let index = next.groups.firstIndex(where: { $0.id == target.id }) {
            if let previous { next.groups[index].members.removeAll { $0.id == previous.pendingGroupMemberID } }
            guard next.groups[index].members.count < IntercomGroup.maximumMemberCount else {
                throw GroupStorageError.invalidUpdate
            }
            let record = next.contactInvitations[next.contactInvitations.count - 1]
            next.groups[index].members.append(
                .init(id: record.pendingGroupMemberID, displayName: record.nickname ?? "Invitation"))
        }
    }

    private func rememberContactDevice(_ member: GroupMember, identity: VerifiedDeviceProof,
                                       now: TimeInterval, in next: inout GroupSnapshot) throws {
        let existing = identity.principal.flatMap { principal in next.users.first { $0.principal == principal } }
        try next.remember(member, identity: identity)
        guard let existing, let recipient = identity.principal, !existing.memberIDs.contains(member.id) else { return }
        let available = GroupSnapshot.maximumGroupDeliveries - next.groupDeliveries.count
        guard available > 0 else { return }
        let invitations = Dictionary(grouping: next.groupDeliveries.filter {
            $0.direction == .outgoing && $0.recipient == recipient
        }, by: \.groupID)
        let deliveries = next.groups.compactMap { group -> GroupDeliveryRecord? in
            guard group.kind == .group, isSelectedGroupDeliveryRecipient(existing, in: group),
                  !group.excludesMember(member.id, principal: recipient),
                  let records = invitations[group.id], let latest = records.last, latest.expiresAt > now,
                  records.contains(where: { $0.noticeID == latest.noticeID && $0.state != .cancelled }),
                  !records.contains(where: { $0.noticeID == latest.noticeID && $0.recipientMemberID == member.id })
            else { return nil }
            // This is another delivery of the same invitation, with its original expiry and notification.
            return .init(noticeID: latest.noticeID, groupID: group.id, recipient: recipient,
                recipientMemberID: member.id, recipientKey: identity.publicKey, expiresAt: latest.expiresAt)
        }
        try appendGroupDeliveries(Array(deliveries.prefix(available)), to: &next)
    }

    func acceptContactInvitation(_ token: GroupInviteToken, accepted: AcceptedDirectInvitation,
                                 localDisplayName: String, now: TimeInterval) throws {
        try token.validate(contactBootstrap: true)
        guard let snapshot, let context = token.directInvitation?.context,
              accepted.receipt.invitation == context, accepted.receipt.inviteeMemberID == localMemberID,
            accepted.inviter.memberID == token.inviterMemberID, !token.isExpired(now: now)
        else { throw GroupStorageError.invalidUpdate }
        if let existing = snapshot.contactInvitations.first(where: { $0.id == context.id }) {
            guard existing.direction == .incoming, existing.state == .pending,
                  existing.receiptID == accepted.receipt.id,
                  existing.peerMemberID == accepted.inviter.memberID,
                  existing.peerDeviceKey == accepted.inviter.publicKey else { throw GroupStorageError.invalidUpdate }
            // Reopening an existing pending link must not recreate a deleted user.
            return
        }
        let payload = ContactInvitationPayload(token: token, receipt: accepted.receipt)
        let inviter = GroupMember(id: accepted.inviter.memberID, displayName: inviterName(for: token))
        let call = try contactDirectCall(with: inviter, localDisplayName: localDisplayName, token: token,
                                         groups: try snapshot.groups.map { try $0.group() })
        let joiningGroups = try groupsByJoining(
            token.invitedGroup, inviter: inviter, identity: accepted.inviter, localDisplayName: localDisplayName,
            groups: call.groups)
        let keys = token.invitedGroup.map { [GroupAccessCredential(groupID: $0.id, secret: $0.secret)] } ?? []
        try update(joiningGroups, credential: call.credential, additionalCredentials: keys) { next in
            if let target = token.invitedGroup, let index = next.groups.firstIndex(where: { $0.id == target.id }) {
                if !snapshot.groups.contains(where: { $0.id == target.id }) {
                    next.groups[index].joinedByInvitation = true
                    next.groups[index].groupTabOfferAcknowledged = false
                }
                try next.groups[index].rememberInvitationDevice(accepted.inviter)
            }
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
            try self.rememberContactDevice(inviter, identity: accepted.inviter, now: now, in: &next)
            let reference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations.append(.init(id: context.id, direction: .incoming, expiresAt: context.expiresAt,
                credentialReference: reference, receiptID: accepted.receipt.id,
                peerMemberID: accepted.inviter.memberID, peerDeviceKey: accepted.inviter.publicKey,
                    personID: next.users.first(where: { $0.memberIDs.contains(accepted.inviter.memberID) })?.id,
                    invitedGroupID: token.invitedGroup?.id))
        }
    }

    func confirmContactInvitation(
        _ verified: VerifiedDirectInvitation, localDisplayName: String, now: TimeInterval,
        receivedBySharing: Bool = false
    ) throws {
        let receipt = verified.receipt
        guard let snapshot, let context = receipt.invitation, context.contactBootstrap == true,
              receipt.inviterMemberID == localMemberID, now < context.expiresAt,
              let old = snapshot.contactInvitations.first(where: { $0.id == context.id }),
              old.direction == .outgoing, old.canResume else { throw GroupStorageError.invalidUpdate }
        if old.state == .confirmed {
            guard old.receiptID == receipt.id, old.peerMemberID == verified.identity.memberID,
                  old.peerDeviceKey == verified.identity.publicKey else { throw GroupStorageError.identityConflict }
            if receivedBySharing && old.receivedBySharing != true {
                try amendContactInvitation(context.id, in: snapshot) { $0.receivedBySharing = true }
            }
            return
        }
        var payload = try contactInvitationPayload(context.id)
        guard payload.token.directInvitation?.context == context else { throw GroupStorageError.identityConflict }
        if let targetID = old.invitedGroupID,
           snapshot.groups.first(where: { $0.id == targetID })?.removedMembers?.contains(where: {
               $0.matches(verified.identity.memberID, principal: verified.identity.principal)
                   && $0.blocksInvitation(context.id, issuedAt: payload.token.issuedAt)
           }) == true { throw GroupStorageError.identityConflict }
        payload.receipt = receipt
        let recipient = GroupMember(id: verified.identity.memberID, displayName: receipt.displayName)
        let call = try contactDirectCall(with: recipient, localDisplayName: localDisplayName, token: payload.token,
                                         groups: try snapshot.groups.map { try $0.group() })
        try update(call.groups, credential: call.credential) { next in
            guard let index = next.contactInvitations.firstIndex(where: { $0.id == context.id }) else {
                throw GroupStorageError.invalidUpdate
            }
            try self.rememberContactAcceptingInvitation(
                recipient, identity: verified.identity, old: old, now: now, in: &next
            )
            try Self.applyConfirmedContactToGroup(recipient, identity: verified.identity, old: old, in: &next)
            next.contactInvitations[index].credentialReference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations[index].state = .confirmed
            next.contactInvitations[index].receivedBySharing = receivedBySharing ? true : nil
            next.contactInvitations[index].receiptID = receipt.id
            next.contactInvitations[index].peerMemberID = verified.identity.memberID
            next.contactInvitations[index].peerDeviceKey = verified.identity.publicKey
        }
    }

    private func rememberContactAcceptingInvitation(
        _ recipient: GroupMember, identity: VerifiedDeviceProof, old: ContactInvitationRecord, now: TimeInterval,
        in next: inout GroupSnapshot
    ) throws {
        let alreadyKnown = next.users.contains { $0.memberIDs.contains(recipient.id)
            || (identity.principal != nil && $0.principal == identity.principal) }
        try rememberContactDevice(recipient, identity: identity, now: now, in: &next)
        if let personID = old.personID,
            let placeholder = next.users.first(where: { $0.id == personID && !$0.isRegistered }),
           let registered = next.users.firstIndex(where: { $0.memberIDs.contains(recipient.id) }) {
            // A newly verified person inherits the original local ID and name. An already known
            // identity keeps its ID; the completed exchange resolves an open draft to that person.
            if !alreadyKnown {
                next.users[registered].id = personID
                next.users[registered].localName = placeholder.localName
                next.users[registered].usesProvisionalName = placeholder.usesProvisionalName
            }
            next.users.removeAll { $0.id == placeholder.id && !$0.isRegistered }
        }
        if !alreadyKnown, old.personID == nil, let nickname = old.nickname,
           let user = next.users.firstIndex(where: { $0.memberIDs.contains(recipient.id) }),
           next.users[user].localName == nil {
            next.users[user].localName = nickname
        }
    }

    private static func applyConfirmedContactToGroup(
        _ recipient: GroupMember, identity: VerifiedDeviceProof, old: ContactInvitationRecord,
        in next: inout GroupSnapshot
    ) throws {
        if let targetID = old.invitedGroupID {
            guard let groupIndex = next.groups.firstIndex(where: { $0.id == targetID && $0.kind == .group }),
                let slot = next.groups[groupIndex].members.firstIndex(where: {
                    $0.id == old.pendingGroupMemberID
                })
            else { throw GroupStorageError.invalidUpdate }
            next.groups[groupIndex].reinstateMembers {
                $0.matches(recipient.id, principal: identity.principal)
            }
            let alreadyMember = next.groups[groupIndex].members.contains { $0.id == recipient.id }
                || (identity.principal.map { principal in
                    next.groups[groupIndex].accountDevices.values.contains { $0.principal == principal }
                } ?? false)
            if alreadyMember { next.groups[groupIndex].members.remove(at: slot) } else {
                next.groups[groupIndex].members[slot] = .init(id: recipient.id, displayName: recipient.displayName)
                if let principal = identity.principal {
                    next.groups[groupIndex].accountDevices[recipient.id] = .init(
                        principal: principal, publicKey: identity.publicKey)
                }
            }
            try next.groups[groupIndex].rememberInvitationDevice(identity)
        }
    }

    /// A contact invitation completes the pair call in the same commit as the user.
    /// Both sides derive one call key from the invitation secret they already share,
    /// so a nearby call needs no later key exchange or Internet service. A
    /// re-invitation replaces an earlier key on both sides.
    private func contactDirectCall(
        with remote: GroupMember, localDisplayName: String, token: GroupInviteToken, groups: [IntercomGroup]
    ) throws -> (groups: [IntercomGroup], credential: GroupAccessCredential) {
        guard let localMemberID else { throw GroupStorageError.invalidUpdate }
        let members = [GroupMember(id: localMemberID, displayName: localDisplayName), remote]
        let id = IntercomGroup.directCallID(memberIDs: members.map(\.id))
        let call =
            try groups.first { $0.id == id }
            ?? IntercomGroup(id: id, name: "Direct Call", members: members, kind: .direct)
        guard call.kind == .direct else { throw GroupStorageError.identityConflict }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.groupSecret.utf8)),
            salt: Data("rideintercom.contact-direct-call.v1".utf8), info: Data(id.uuidString.utf8), outputByteCount: 32)
        let secret = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return ([call] + groups.filter { $0.id != id }, .init(groupID: id, secret: secret))
    }

    func contactInvitationPayload(_ id: UUID) throws -> ContactInvitationPayload {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        return try withCurrentSnapshot(snapshot) {
            guard let record = snapshot.contactInvitations.first(where: { $0.id == id }), record.canResume,
                let reference = record.credentialReference, let secret = try credentialSecret(reference: reference)
            else { throw GroupStorageError.invalidUpdate }
            let payload = try ContactInvitationPayload.decodeSecret(secret, record: record)
            guard (record.direction == .outgoing) == (payload.token.inviterMemberID == localMemberID) else {
                throw GroupStorageError.identityConflict
            }
            return payload
        }
    }

    func removeExpiredContactInvitations(now: TimeInterval) throws {
        guard now.isFinite, let snapshot else { throw GroupStorageError.invalidUpdate }
        guard snapshot.contactInvitations.contains(where: { $0.expiresAt <= now && $0.state != .expired }) else {
            return
        }
        try amend(snapshot) { next in
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
        }
    }

    func completeContactNotification(_ id: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .incoming, record.state == .pending else { throw GroupStorageError.invalidUpdate }
        try setContactInvitationState(id, state: .delivered)
    }

    func markContactInternetAcknowledged(_ id: UUID, receiptID: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .outgoing, record.state == .confirmed, record.receiptID == receiptID,
              record.internetAcknowledged != true else { return }
        try amendContactInvitation(id, in: snapshot) { $0.internetAcknowledged = true }
    }

    func markContactInternetAcceptanceSubmitted(_ id: UUID, receiptID: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .incoming, record.state == .pending, record.receiptID == receiptID,
              record.internetAcceptanceSubmitted != true else { return }
        try amendContactInvitation(id, in: snapshot) { $0.internetAcceptanceSubmitted = true }
    }

    func cancelContactInvitation(_ id: UUID) throws {
        try setContactInvitationState(id, state: .cancelled)
    }

    /// A share destination took the link: the invitation now waits to be accepted.
    func markContactInvitationSent(_ id: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.isPendingOutgoing else { throw GroupStorageError.invalidUpdate }
        guard record.sent == false else { return }
        try amendContactInvitation(id, in: snapshot) { record in record.sent = true }
    }

    /// Names an outgoing invitation before it completes; nil clears the name.
    func setContactInvitationNickname(_ id: UUID, nickname: String?) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.isPendingOutgoing else { throw GroupStorageError.invalidUpdate }
        guard record.nickname != nickname else { return }
        try amendContactInvitation(id, in: snapshot) { record in record.nickname = nickname }
    }

    private func amendContactInvitation(_ id: UUID, in snapshot: GroupSnapshot,
                                        _ change: (inout ContactInvitationRecord) -> Void) throws {
        try amend(snapshot) { next in
            guard let index = next.contactInvitations.firstIndex(where: { $0.id == id }) else {
                throw GroupStorageError.invalidUpdate
            }
            change(&next.contactInvitations[index])
        }
    }

    private func setContactInvitationState(_ id: UUID, state: ContactInvitationRecord.State) throws {
        guard let snapshot, snapshot.contactInvitations.contains(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        try amendContactInvitation(id, in: snapshot) { record in
            record.state = state
            record.credentialReference = nil
        }
    }
}
