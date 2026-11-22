import Foundation

/// The manifest replacement is the sole commit point. Keys are immutable versions;
/// failed work may leave orphan keys, but never changes a committed key in place.
final class GroupRepository {
    private let store: GroupStoring
    private let credentials: GroupCredentialStoring
    private(set) var snapshot: GroupSnapshot?
    private var isWritable = false
    private(set) var localMemberID: String?
    private(set) var missingCredentialGroupIDs: Set<UUID> = []
    private(set) var needsCleanup = false
    var writableSnapshot: GroupSnapshot? { isWritable ? snapshot : nil }
    var onCommittedChange: (() -> Void)?
    var users: [SavedUser] { snapshot?.users ?? [] }
    var contactInvitations: [ContactInvitationRecord] { snapshot?.contactInvitations ?? [] }
    var groupDeliveries: [GroupDeliveryRecord] { snapshot?.groupDeliveries ?? [] }
    var contactDeletions: [ContactDeletionNotice] { snapshot?.contactDeletions ?? [] }
    var contactDeletionReceipts: [ContactDeletionReceipt] { snapshot?.contactDeletionReceipts ?? [] }
    var contactDeletionPublications: [ContactDeletionPublication] { snapshot?.contactDeletionPublications ?? [] }
    var contactDeletionRelayReceipts: [ContactDeletionRelayReceipt] { snapshot?.contactDeletionRelayReceipts ?? [] }
    var contactDeletionFormerPairs: [ContactDeletionFormerPair] { snapshot?.contactDeletionFormerPairs ?? [] }

    init(store: GroupStoring, credentials: GroupCredentialStoring) {
        self.store = store; self.credentials = credentials
    }

    func load(localMemberID: String) throws -> [IntercomGroup] {
        self.localMemberID = localMemberID
        try store.lock(); defer { store.unlock() }
        do {
            let saved = try store.read()
            var current = saved ?? GroupSnapshot()
            _ = try validateIdentity(current, localMemberID: localMemberID)
            if current.version < GroupSnapshot.currentVersion {
                current = current.upgraded()
            }
            if saved?.version != current.version {
                try store.commit(current)
                guard try store.read() == current else { throw GroupStorageError.verificationFailed }
            }
            // Loading happens with no call running. Repair checkpoints left by older deletion paths
            // in the same commit as orphan cleanup, before reclaiming their keys.
            let beforeMaintenance = current
            current.groups.removeAll { isOrphanedDirectGroup($0, users: current.users) }
            current.discardIssuedOrdinaryGroupInvitations(now: Date().timeIntervalSince1970)
            reconcileInvitations(in: &current)
            if current != beforeMaintenance {
                current.generation = UUID()
                try store.commit(current)
                guard try store.read() == current else { throw GroupStorageError.verificationFailed }
            }
            let groups = try validateIdentity(current, localMemberID: localMemberID)
            var missing: Set<UUID> = []
            for record in current.groups {
                if let ref = record.credentialReference {
                    if try credentials.secret(reference: ref) == nil { missing.insert(record.id) }
                } else { missing.insert(record.id) }
            }
            snapshot = current; missingCredentialGroupIDs = missing; isWritable = true
            cleanup(current)
            return groups
        } catch { isWritable = false; throw error }
    }

    private func validateIdentity(_ current: GroupSnapshot, localMemberID: String) throws -> [IntercomGroup] {
        guard current.contactDeletions.allSatisfy({ $0.target.senderMemberID == localMemberID }),
              current.contactDeletionReceipts.allSatisfy({ $0.target.recipientMemberID == localMemberID }),
              current.contactDeletionFormerPairs.allSatisfy({ $0.localMemberID == localMemberID }) else {
            throw IntercomGroupError.invalidStoredGroups
        }
        return try current.groups.map { record in
            var group = try record.group()
            guard let index = group.members.firstIndex(where: { $0.id == localMemberID }) else {
                throw IntercomGroupError.invalidStoredGroups
            }
            group.members.insert(group.members.remove(at: index), at: 0)
            return group
        }
    }

    func credential(for id: UUID) throws -> GroupAccessCredential? {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        return try withCurrentSnapshot(snapshot) {
            guard let reference = snapshot.groups.first(where: { $0.id == id })?.credentialReference,
                  let secret = try credentialSecret(reference: reference) else { return nil }
            return .init(groupID: id, secret: secret)
        }
    }

    /// Hold the store lock through the operation and require a reload after a stale snapshot.
    func withCurrentSnapshot<T>(_ expected: GroupSnapshot, _ perform: () throws -> T) throws -> T {
        try store.lock()
        defer { store.unlock() }
        guard try store.read() == expected else {
            isWritable = false
            throw GroupStorageError.changedByAnotherProcess
        }
        return try perform()
    }

    func credentialSecret(reference: UUID) throws -> String? {
        try credentials.secret(reference: reference)
    }

    func prepareKey(_ secret: String) throws -> UUID {
        let reference = UUID()
        try credentials.saveSecret(secret, reference: reference)
        guard try credentials.secret(reference: reference) == secret else {
            throw IntercomGroupError.credentialVerificationFailed
        }
        return reference
    }

    func update(
        _ groups: [IntercomGroup], credential: GroupAccessCredential?,
        additionalCredentials: [GroupAccessCredential] = [], users: [SavedUser]? = nil,
        now: TimeInterval = Date().timeIntervalSince1970,
        modify: (inout GroupSnapshot) throws -> Void = { _ in }
    ) throws {
        guard let previous = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        try withCurrentSnapshot(previous) {
            var next = try makeUpdatedSnapshot(groups, users: users, from: previous, now: now)
            try modify(&next)
            let allCredentials = (credential.map { [$0] } ?? []) + additionalCredentials
            next.discardIssuedOrdinaryGroupInvitations(now: now, replacingKeys: Set(allCredentials.map(\.groupID)))
            let retainedGroupIDs = Set(next.groups.map(\.id))
            for removed in previous.groups where removed.kind == .group && !retainedGroupIDs.contains(removed.id) {
                next.retireGroupLinks(from: removed)
            }
            next.discardExpiredRetiredGroupLinks(now: now)
            reconcileInvitations(in: &next)
            for index in next.groups.indices { next.groups[index].discardInvitationKeysForDepartedMembers() }
            next.synchronizeUserReferences()
            do { _ = try next.encoded() } catch { throw GroupStorageError.invalidUpdate }
            for credential in allCredentials {
                guard let index = next.groups.firstIndex(where: { $0.id == credential.groupID }) else {
                    throw GroupStorageError.invalidUpdate
                }
                next.groups[index].credentialReference = try prepareKey(credential.secret)
            }
            do {
                try store.commit(next)
                guard try store.read() == next else { throw GroupStorageError.verificationFailed }
            } catch {
                // The operation can fail after rename. Re-read before allowing another
                // write; never roll a committed manifest back or delete its new key.
                isWritable = false
                throw error
            }
            snapshot = next
            missingCredentialGroupIDs.formIntersection(Set(next.groups.map(\.id)))
            for credential in allCredentials { missingCredentialGroupIDs.remove(credential.groupID) }
            cleanup(next)
        }
        onCommittedChange?()
    }

    private func makeUpdatedSnapshot(
        _ groups: [IntercomGroup], users: [SavedUser]?, from previous: GroupSnapshot, now: TimeInterval
    ) throws -> GroupSnapshot {
        // Validate the requested edit before directory names are reapplied.
        do {
            for group in groups { _ = try GroupSnapshot.Record(group).group() }
        } catch {
            throw GroupStorageError.invalidUpdate
        }
        var next = GroupSnapshot(groups: groups.map { group in
            let old = previous.groups.first(where: { $0.id == group.id })
            var record = GroupSnapshot.Record(group, credentialReference: old?.credentialReference)
            record.lastSponsoredStart = old?.lastSponsoredStart
            record.pendingInvitation = old?.pendingInvitation
            record.receivedInvitationIDs = old?.receivedInvitationIDs ?? []
            record.joinedByInvitation = old?.joinedByInvitation
            record.groupTabOfferAcknowledged = old?.groupTabOfferAcknowledged
            record.removedMembers = old?.removedMembers
            record.invitationDeviceKeys = old?.invitationDeviceKeys
            return record
        }, users: users ?? previous.users, contactInvitations: previous.contactInvitations,
           groupDeliveries: previous.groupDeliveries, groupLinkReceipts: previous.groupLinkReceipts,
           groupRemovalReceipts: previous.groupRemovalReceipts.filter { $0.expiresAt > now },
           nearbyGroupCancellations: previous.nearbyGroupCancellations.filter { $0.expiresAt > now },
           contactDeletions: previous.contactDeletions.filter { $0.target.expiresAt > now },
           contactDeletionReceipts: previous.contactDeletionReceipts.filter { $0.target.expiresAt > now },
            contactDeletionPublications: previous.contactDeletionPublications.filter {
                Double($0.expiresAt) > now * 1_000
            },
            contactDeletionRelayReceipts: previous.contactDeletionRelayReceipts.filter {
                Double($0.expiresAt) > now * 1_000
            },
           contactDeletionFormerPairs: previous.contactDeletionFormerPairs.filter { $0.expiresAt > now })
        next.issuedOrdinaryGroupInvitations = previous.issuedOrdinaryGroupInvitations
        return next
    }

    /// An edit that leaves the groups themselves as they are stored.
    func amend(
        _ snapshot: GroupSnapshot, credential: GroupAccessCredential? = nil,
        now: TimeInterval = Date().timeIntervalSince1970,
        _ modify: (inout GroupSnapshot) throws -> Void
    ) throws {
        try update(snapshot.groups.map { try $0.group() }, credential: credential, now: now, modify: modify)
    }

    private func cleanup(_ current: GroupSnapshot) {
        do {
            let live = Set(current.credentialReferences)
            for reference in try credentials.references().subtracting(live) {
                try credentials.delete(reference: reference)
            }
            needsCleanup = false
        } catch { needsCleanup = true }
    }

    func reset() throws {
        try store.lock(); defer { store.unlock() }
        // A newer schema must be opened by the matching app, not reset by this one.
        do {
            _ = try store.read()
        } catch GroupStorageError.unsupportedVersion {
            throw GroupStorageError.unsupportedVersion
        } catch {
            // Preserve malformed bytes before replacing them.
        }
        try store.archive()
        let empty = GroupSnapshot()
        try store.commit(empty)
        guard try store.read() == empty else { isWritable = false; throw GroupStorageError.verificationFailed }
        snapshot = empty; isWritable = true; missingCredentialGroupIDs = []
        cleanup(empty)
    }

}

private extension GroupRepository {
    func reconcileInvitations(in next: inout GroupSnapshot) {
        // Append order identifies the latest invitation even when the device clock changes.
        let latestNotices = latestGroupDeliveryNotices(in: next)
        next.groupDeliveries.removeAll { record in
            record.direction == .outgoing && record.state == .received
                && latestNotices[record.groupID]?[record.recipient] != record.noticeID
        }
        for index in next.groupDeliveries.indices {
            let record = next.groupDeliveries[index]
            guard record.direction == .outgoing, record.expiredOutcome == nil,
                  record.state == .pending || record.state == .queued else { continue }
            let supersededRedelivery =
                record.sourceRequestID != nil
                && latestNotices[record.groupID]?[record.recipient] != record.noticeID
            if supersededRedelivery || !isSelectedGroupDelivery(record, in: next) {
                next.groupDeliveries[index].moveOutgoing(to: .cancelled)
            }
        }
        let people = Set(next.users.map(\.id))
        let members = Set(next.users.flatMap(\.memberIDs))
        for index in next.contactInvitations.indices {
            let record = next.contactInvitations[index]
            // After confirmation, the peer may have merged into an existing saved person.
            let hasPerson = record.peerMemberID.map(members.contains) ?? record.personID.map(people.contains) ?? true
            let group = record.invitedGroupID.flatMap { groupID in
                next.groups.firstIndex { $0.id == groupID && $0.kind == .group }
            }
            let targetExists = record.invitedGroupID == nil || group.map { index in
                    record.direction == .incoming
                        || next.groups[index].members.contains { $0.id == record.pendingGroupMemberID }
            } == true
            // An expired outgoing record can still renew its group invitation while its slot exists.
            if !hasPerson || ((record.state == .pending || record.isExpiredTombstone) && !targetExists) {
                next.contactInvitations[index].state = .cancelled
                next.contactInvitations[index].credentialReference = nil
            }
            if record.direction == .outgoing, next.contactInvitations[index].state == .cancelled, let group {
                next.groups[group].members.removeAll { $0.id == record.pendingGroupMemberID }
            }
        }
        var pendingByGroup: [UUID: Set<UUID>] = [:]
        for invitation in next.contactInvitations where invitation.isPendingOutgoing {
            if let group = invitation.invitedGroupID { pendingByGroup[group, default: []].insert(invitation.id) }
        }
        for index in next.groups.indices {
            let groupID = next.groups[index].id
            if let inviter = next.groups[index].pendingInvitation?.inviterMemberID, !members.contains(inviter) {
                next.groups[index].pendingInvitation = nil
            }
            next.groups[index].discardRemovalHistory(withPendingInvitations: pendingByGroup[groupID] ?? [])
        }
    }
}
