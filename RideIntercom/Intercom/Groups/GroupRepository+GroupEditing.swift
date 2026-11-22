import Foundation

extension GroupRepository {
    func save(_ groups: [IntercomGroup], deliveries: [GroupDeliveryRecord] = []) throws {
        try update(groups, credential: nil) { try self.appendGroupDeliveries(deliveries, to: &$0) }
    }
    func save(
        _ groups: [IntercomGroup], credential: GroupAccessCredential,
        acceptedInvitation: AcceptedDirectInvitation? = nil,
        inviterName: String? = nil, deliveries: [GroupDeliveryRecord] = [],
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        let previousGroupIDs = Set(snapshot?.groups.map(\.id) ?? [])
        try update(groups, credential: credential, now: now) { next in
            try self.appendGroupDeliveries(deliveries, to: &next)
            if let receipt = acceptedInvitation {
                try self.storeAcceptedInvitation(receipt, inviterName: inviterName, in: &next)
                // Joined through someone's invitation: they own a regular group, and you can only leave it.
                if let index = next.groups.firstIndex(where: { $0.id == receipt.receipt.groupID }),
                    next.groups[index].kind != .direct,
                   previousGroupIDs.contains(receipt.receipt.groupID) == false {
                    next.groups[index].joinedByInvitation = true
                    next.groups[index].groupTabOfferAcknowledged = false
                }
            }
        }
    }
    func delete(_ id: UUID, remaining: [IntercomGroup], receipt: GroupSnapshot.GroupRemovalReceipt? = nil,
                now: TimeInterval = Date().timeIntervalSince1970) throws {
        try update(remaining, credential: nil, now: now) { next in
            try Self.rememberGroupRemoval(receipt, for: id, in: &next, now: now)
            Self.cancelPendingGroupReceipts(in: &next) { $0.groupID == id }
            recordBackupRemoval(id, kind: .group, afterRemovingFrom: &next)
        }
    }

    func hasAppliedGroupRemoval(_ receipt: GroupSnapshot.GroupRemovalReceipt, now: TimeInterval) throws -> Bool {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard receipt.isValid, receipt.expiresAt > now else { throw GroupStorageError.invalidUpdate }
        guard let applied = snapshot.groupRemovalReceipts.first(where: {
            $0.groupID == receipt.groupID && $0.eventID == receipt.eventID && $0.expiresAt > now
        }) else { return false }
        // The original issuer might no longer be in the roster after a successful removal.
        // In that case only a byte-for-byte match to the verified event can be acknowledged.
        guard applied == receipt else { throw GroupStorageError.invalidUpdate }
        return try withCurrentSnapshot(snapshot) { true }
    }

    private static func rememberGroupRemoval(_ receipt: GroupSnapshot.GroupRemovalReceipt?, for groupID: UUID,
                                             in snapshot: inout GroupSnapshot, now: TimeInterval) throws {
        guard let receipt else { return }
        guard receipt.groupID == groupID, receipt.isValid, receipt.expiresAt > now,
              !snapshot.groupRemovalReceipts.contains(where: { $0.groupID == groupID && $0.eventID == receipt.eventID })
        else { throw GroupStorageError.invalidUpdate }
        snapshot.groupRemovalReceipts.append(receipt)
    }

    func removeGroupMember(_ memberID: String, from groupID: UUID, receipt: GroupSnapshot.GroupRemovalReceipt? = nil,
                           now: TimeInterval) throws -> Set<String> {
        guard let snapshot, let localMemberID, memberID != localMemberID,
              IntercomGroup.isValidMemberID(memberID),
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID && $0.kind == .group })
        else { throw GroupStorageError.invalidUpdate }
        let isPendingSlot = memberID.hasPrefix(GroupMember.pendingInvitePrefix)
        guard
            !isPendingSlot
                || (receipt == nil && snapshot.groups[index].members.contains(where: { $0.id == memberID }))
        else { throw GroupStorageError.invalidUpdate }
        var groups = try snapshot.groups.map { try $0.group() }
        let binding = groups[index].accountDevices[memberID]
        let user = snapshot.users.first {
            $0.memberIDs.contains(memberID) || (binding != nil && $0.principal == binding?.principal)
        }
        let ids = Set(user?.memberIDs ?? []).union([memberID]).subtracting([localMemberID])
        groups[index].members.removeAll { ids.contains($0.id) }
        groups[index].accountDevices = groups[index].accountDevices.filter { !ids.contains($0.key) }
        try update(groups, credential: nil, now: now) { next in
            try Self.rememberGroupRemoval(receipt, for: groupID, in: &next, now: now)
            // A verified removal can arrive before this device ever sees the member.
            guard !isPendingSlot else { return }
            let pending = next.contactInvitations.filter {
                $0.direction == .outgoing && $0.state == .pending && $0.invitedGroupID == groupID
            }
            let principal = binding?.principal ?? user?.principal
            let removed = GroupSnapshot.RemovedMember(memberIDs: ids, principal: principal, removedAt: now,
                priorInvitationIDs: Set(pending.map(\.id)))
            var removals = next.groups[index].removedMembers ?? []
            // Every still-pending invitation covered by a previous removal is covered again.
            removals.removeAll { $0.memberIDs == ids && $0.principal == principal }
            next.groups[index].removedMembers = removals + [removed]
        }
        return ids
    }

    func saveGroupMembers(_ group: IntercomGroup, selectedUsers: Set<UUID>, deliveries: [GroupDeliveryRecord]) throws {
        guard let snapshot, group.kind == .group,
              let index = snapshot.groups.firstIndex(where: { $0.id == group.id && $0.kind == .group })
        else { throw GroupStorageError.invalidUpdate }
        var groups = try snapshot.groups.map { try $0.group() }
        groups[index] = group
        try update(groups, credential: nil) { next in
            Self.restoreExplicitlySelectedMembers(selectedUsers, in: group.id, snapshot: &next)
            try self.appendGroupDeliveries(deliveries, to: &next)
        }
    }

    private static func restoreExplicitlySelectedMembers(
        _ ids: Set<UUID>, in groupID: UUID, snapshot: inout GroupSnapshot
    ) {
        guard !ids.isEmpty, let index = snapshot.groups.firstIndex(where: { $0.id == groupID }) else { return }
        let users = snapshot.users.filter { ids.contains($0.id) }
        snapshot.groups[index].reinstateMembers { removal in
            users.contains { user in user.memberIDs.contains { removal.matches($0, principal: user.principal) } }
        }
    }

    func lastSponsoredStart(for groupID: UUID) -> TimeInterval? {
        snapshot?.groups.first { $0.id == groupID }?.lastSponsoredStart
    }

    func recordSponsoredStart(_ start: TimeInterval, for groupID: UUID, now: TimeInterval) throws {
        guard CallAccessState.validStart(start, now: now), let snapshot,
            let index = snapshot.groups.firstIndex(where: { $0.id == groupID })
        else { throw GroupStorageError.invalidUpdate }
        if let previous = snapshot.groups[index].lastSponsoredStart,
           CallAccessState.validStart(previous, now: now), previous >= start { return }
        try amend(snapshot) { next in
            next.groups[index].lastSponsoredStart = start
        }
    }

    /// You own a regular group you made here; one you joined through an invitation is someone else's.
    func ownsGroup(_ groupID: UUID) -> Bool {
        snapshot?.groups.first { $0.id == groupID }?.joinedByInvitation != true
    }

    var unacknowledgedGroupTabOffers: [UUID] {
        snapshot?.groups.filter {
            $0.kind == .group && $0.joinedByInvitation == true && $0.groupTabOfferAcknowledged == false
        }.map(\.id) ?? []
    }

    /// One response covers all invitations already received, so a batch never produces repeated alerts.
    func acknowledgeGroupTabOffers() throws {
        guard let snapshot, !unacknowledgedGroupTabOffers.isEmpty else { return }
        try update(try snapshot.groups.map { try $0.group() }, credential: nil) { next in
            for index in next.groups.indices where next.groups[index].groupTabOfferAcknowledged == false {
                next.groups[index].groupTabOfferAcknowledged = true
            }
        }
    }

    func storedGroup(_ groupID: UUID) -> IntercomGroup? {
        snapshot?.groups.first { $0.id == groupID }.flatMap { try? $0.group() }
    }

    /// Reuse a saved device call only when the person's registration identifies one such call.

    /// A selection of new people and its group is one operation, including every reserved slot.
    func saveGroupInvitationSelection(
        _ group: IntercomGroup, credential: GroupAccessCredential,
        invitees: [(person: SavedUser, token: GroupInviteToken)], now: TimeInterval,
        existingMembers: (selectedUsers: Set<UUID>, deliveries: [GroupDeliveryRecord])
    ) throws {
        guard let snapshot, group.kind == .group, credential.groupID == group.id, !invitees.isEmpty,
              group.members.count + invitees.count <= IntercomGroup.maximumMemberCount,
              Set(invitees.map { $0.person.id }).count == invitees.count else { throw GroupStorageError.invalidUpdate }
        if snapshot.groups.contains(where: { $0.id == group.id }) {
            guard try self.credential(for: group.id)?.secret == credential.secret else {
                throw GroupStorageError.identityConflict
            }
        }
        var reserved = group
        for (person, token) in invitees {
            try token.validate(contactBootstrap: true)
            guard let context = token.directInvitation?.context, let target = token.invitedGroup,
                  target.id == group.id, target.name == group.name, target.secret == credential.secret,
                  token.inviterMemberID == localMemberID, !token.isExpired(now: now), token.verifySignature(),
                  !person.isRegistered, IntercomGroup.isValidName(person.resolvedDisplayName),
                  !snapshot.users.contains(where: { $0.id == person.id }),
                !snapshot.contactInvitations.contains(where: { $0.id == context.id }),
                let proof = token.identityProof
            else { throw GroupStorageError.invalidUpdate }
            _ = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: token.inviterMemberID)
            reserved.members.append(
                .init(
                    id: GroupMember.pendingInvitePrefix + "contact-" + context.id.uuidString.lowercased(),
                    displayName: person.resolvedDisplayName))
        }
        try update(
            [reserved] + snapshot.groups.filter { $0.id != group.id }.map { try $0.group() },
            credential: credential
        ) { next in
            Self.restoreExplicitlySelectedMembers(existingMembers.selectedUsers, in: group.id, snapshot: &next)
            try self.appendGroupDeliveries(existingMembers.deliveries, to: &next)
            for (person, token) in invitees {
                guard let context = token.directInvitation?.context else { throw GroupStorageError.invalidUpdate }
                next.users.append(person)
                next.contactInvitations.append(.init(id: context.id, direction: .outgoing, expiresAt: context.expiresAt,
                    credentialReference: try self.prepareKey(ContactInvitationPayload(token: token).encodedSecret()),
                    nickname: person.resolvedDisplayName, sent: false, personID: person.id, invitedGroupID: group.id))
            }
        }
    }

    func appendGroupDeliveries(_ records: [GroupDeliveryRecord], to next: inout GroupSnapshot) throws {
        for record in records {
            guard record.isValid, record.direction == .outgoing, record.state == .pending,
                record.credentialReference == nil,
                  !next.groupDeliveries.contains(where: { $0.id == record.id }),
                  isSelectedGroupDelivery(record, in: next) else { throw GroupStorageError.invalidUpdate }
            next.groupDeliveries.append(record)
        }
    }

    func isSelectedGroupDelivery(_ record: GroupDeliveryRecord, in snapshot: GroupSnapshot) -> Bool {
        guard let group = snapshot.groups.first(where: { $0.id == record.groupID && $0.kind == .group }) else {
            return false
        }
        let selected: GroupDeliveryRecord
        if let sourceID = record.sourceRequestID {
            guard let source = snapshot.groupDeliveries.first(where: { $0.id == sourceID }),
                  source.sourceRequestID == nil, source.direction == .outgoing, source.state != .cancelled,
                source.groupID == record.groupID, source.recipient == record.recipient,
                source.noticeID == record.noticeID,
                source.expiresAt == record.expiresAt,
                !group.excludesMember(record.recipientMemberID, principal: record.recipient)
            else { return false }
            selected = source
        } else {
            selected = record
        }
        guard
            let user = snapshot.users.first(where: {
                $0.principal == selected.recipient && $0.memberIDs.contains(selected.recipientMemberID)
                  && $0.deviceKeys?[selected.recipientMemberID] == selected.recipientKey })
        else { return false }
        return isSelectedGroupDeliveryRecipient(user, in: group)
    }

    func isSelectedGroupDeliveryRecipient(_ user: SavedUser, in group: GroupSnapshot.Record) -> Bool {
        group.members.contains { user.memberIDs.contains($0.id) }
            || group.accountDevices.values.contains { $0.principal == user.principal }
    }

    func latestGroupDeliveryNotices(in snapshot: GroupSnapshot) -> [UUID: [AccountPrincipal: UUID]] {
        var notices: [UUID: [AccountPrincipal: UUID]] = [:]
        for record in snapshot.groupDeliveries where record.direction == .outgoing {
            notices[record.groupID, default: [:]][record.recipient] = record.noticeID
        }
        return notices
    }

    func groupsByJoining(
        _ target: ContactGroupInvitation?, inviter: GroupMember, identity: VerifiedDeviceProof,
        localDisplayName: String, groups: [IntercomGroup]
    ) throws -> [IntercomGroup] {
        guard let target else { return groups }
        if let existing = groups.first(where: { $0.id == target.id }) {
            guard try matchesSavedGroup(target, kind: existing.kind) else { throw GroupStorageError.identityConflict }
            return groups
        }
        guard let localMemberID else { throw GroupStorageError.invalidUpdate }
        let devices: [String: AccountDeviceBinding] =
            identity.principal.map { [inviter.id: .init(principal: $0, publicKey: identity.publicKey)] } ?? [:]
        let group = try IntercomGroup(id: target.id, name: target.name,
            members: [.init(id: localMemberID, displayName: localDisplayName), inviter], accountDevices: devices)
        return [group] + groups
    }

    func matchesSavedGroup(_ target: ContactGroupInvitation, kind: IntercomGroup.Kind) throws -> Bool {
        guard kind == .group else { return false }
        // A missing or unreadable local credential may be recoverable.
        guard let saved = try credential(for: target.id) else { throw GroupStorageError.identityConflict }
        return saved.secret == target.secret
    }
}
