import CryptoKit
import Foundation

/// The manifest replacement is the sole commit point. Keys are immutable versions;
/// failed work may leave orphan keys, but never changes a committed key in place.
final class GroupRepository {
    private let store: GroupStoring
    private let credentials: GroupCredentialStoring
    private let legacy: LegacyGroupReader?
    private var snapshot: GroupSnapshot?
    private var isWritable = false
    private var localMemberID: String?
    private(set) var missingCredentialGroupIDs: Set<UUID> = []
    private(set) var needsCleanup = false
    var users: [SavedUser] { snapshot?.users ?? [] }
    var contactInvitations: [ContactInvitationRecord] { snapshot?.contactInvitations ?? [] }
    var groupDeliveries: [GroupDeliveryRecord] { snapshot?.groupDeliveries ?? [] }

    init(store: GroupStoring, credentials: GroupCredentialStoring, legacy: LegacyGroupReader? = nil) {
        self.store = store; self.credentials = credentials; self.legacy = legacy
    }

    func load(localMemberID: String) throws -> [IntercomGroup] {
        self.localMemberID = localMemberID
        try store.lock(); defer { store.unlock() }
        do {
            var current = try store.read() ?? migrate(localMemberID: localMemberID)
            _ = try validateIdentity(current, localMemberID: localMemberID)
            if current.version < GroupSnapshot.currentVersion {
                current = current.upgraded()
                try store.commit(current)
                guard try store.read() == current else { throw GroupStorageError.verificationFailed }
            }
            // Loading happens with no call running. Repair checkpoints left by older deletion paths
            // in the same commit as orphan cleanup, before reclaiming their keys.
            let beforeMaintenance = current
            current.groups.removeAll { isOrphanedDirectGroup($0, users: current.users) }
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
        try current.groups.map { record in
            var group = try record.group()
            guard let index = group.members.firstIndex(where: { $0.id == localMemberID }) else { throw IntercomGroupError.invalidStoredGroups }
            group.members.insert(group.members.remove(at: index), at: 0)
            return group
        }
    }

    private func migrate(localMemberID: String) throws -> GroupSnapshot {
        let groups = try legacy?.read() ?? []
        var candidate = GroupSnapshot(groups: groups.map { .init($0) })
        _ = try validateIdentity(candidate, localMemberID: localMemberID)
        for index in candidate.groups.indices {
            if let secret = try legacy?.secret(for: candidate.groups[index].id) {
                candidate.groups[index].credentialReference = try prepareKey(secret)
            }
        }
        try store.commit(candidate)
        guard try store.read() == candidate else { throw GroupStorageError.verificationFailed }
        return candidate
    }

    func credential(for id: UUID) throws -> GroupAccessCredential? {
        guard isWritable, let snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == snapshot else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        guard let reference = snapshot.groups.first(where: { $0.id == id })?.credentialReference,
              let secret = try credentials.secret(reference: reference) else { return nil }
        return .init(groupID: id, secret: secret)
    }

    /// The inviter's own name wins; the name already saved for them fills in for an invitation that carries none.
    func inviterName(for token: GroupInviteToken) -> String {
        token.inviterDisplayName ?? users.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName ?? "Inviter"
    }

    func save(_ groups: [IntercomGroup], deliveries: [GroupDeliveryRecord] = []) throws {
        try update(groups, credential: nil) { try self.appendGroupDeliveries(deliveries, to: &$0) }
    }
    func save(_ groups: [IntercomGroup], credential: GroupAccessCredential, acceptedInvitation: AcceptedDirectInvitation? = nil,
              inviterName: String? = nil, deliveries: [GroupDeliveryRecord] = [], now: TimeInterval = Date().timeIntervalSince1970) throws {
        let previousGroupIDs = Set(snapshot?.groups.map(\.id) ?? [])
        try update(groups, credential: credential, now: now) { next in
            try self.appendGroupDeliveries(deliveries, to: &next)
            if let receipt = acceptedInvitation {
                try self.storeAcceptedInvitation(receipt, inviterName: inviterName, in: &next)
                // Joined through someone's invitation: they own a regular group, and you can only leave it.
                if let index = next.groups.firstIndex(where: { $0.id == receipt.receipt.groupID }), next.groups[index].kind != .direct,
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
        }
    }

    func hasAppliedGroupRemoval(_ receipt: GroupSnapshot.GroupRemovalReceipt, now: TimeInterval) throws -> Bool {
        guard isWritable, let snapshot else { throw IntercomGroupError.storageUnavailable }
        guard receipt.isValid, receipt.expiresAt > now else { throw GroupStorageError.invalidUpdate }
        guard let applied = snapshot.groupRemovalReceipts.first(where: {
            $0.groupID == receipt.groupID && $0.eventID == receipt.eventID && $0.expiresAt > now
        }) else { return false }
        // The original issuer might no longer be in the roster after a successful removal.
        // In that case only a byte-for-byte match to the verified event can be acknowledged.
        guard applied == receipt else { throw GroupStorageError.invalidUpdate }
        try store.lock()
        defer { store.unlock() }
        guard try store.read() == snapshot else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        return true
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
        guard !isPendingSlot || (receipt == nil && snapshot.groups[index].members.contains(where: { $0.id == memberID }))
        else { throw GroupStorageError.invalidUpdate }
        var groups = try snapshot.groups.map { try $0.group() }
        let binding = groups[index].accountDevices[memberID]
        let user = snapshot.users.first { $0.memberIDs.contains(memberID) || (binding != nil && $0.principal == binding?.principal) }
        let ids = Set(user?.memberIDs ?? []).union([memberID]).subtracting([localMemberID])
        groups[index].members.removeAll { ids.contains($0.id) }
        groups[index].accountDevices = groups[index].accountDevices.filter { !ids.contains($0.key) }
        try update(groups, credential: nil, now: now) { next in
            try Self.rememberGroupRemoval(receipt, for: groupID, in: &next, now: now)
            // A verified removal can arrive before this device ever sees the member.
            guard !isPendingSlot else { return }
            let pending = next.contactInvitations.filter { $0.direction == .outgoing && $0.state == .pending && $0.invitedGroupID == groupID }
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

    private static func restoreExplicitlySelectedMembers(_ ids: Set<UUID>, in groupID: UUID, snapshot: inout GroupSnapshot) {
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
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }) else { throw GroupStorageError.invalidUpdate }
        if let previous = snapshot.groups[index].lastSponsoredStart,
           CallAccessState.validStart(previous, now: now), previous >= start { return }
        try amend(snapshot) { next in
            next.groups[index].lastSponsoredStart = start
        }
    }

    func saveContactPerson(_ id: UUID, name: String, usesProvisionalName: Bool = false) throws {
        guard let snapshot, IntercomGroup.isValidName(name), !snapshot.users.contains(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            next.users.append(SavedUser(id: id, displayName: name, memberIDs: [], localName: name, usesProvisionalName: usesProvisionalName))
        }
    }

    /// The displayed pair of names is checked at the manifest's atomic commit point.
    func resolveProvisionalName(_ id: UUID, localName: String, sharedName: String, useSharedName: Bool) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }),
              snapshot.users[index].needsNameConfirmation,
              snapshot.users[index].localName == localName, snapshot.users[index].displayName == sharedName else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            if useSharedName { next.users[index].localName = nil }
            next.users[index].usesProvisionalName = false
        }
    }

    func renameUser(_ id: UUID, displayName: String) throws {
        guard IntercomGroup.isValidName(displayName) else { throw GroupStorageError.invalidUpdate }
        try setUserLocalName(id, displayName)
    }

    func resetUserName(_ id: UUID) throws { try setUserLocalName(id, nil) }

    private func setUserLocalName(_ id: UUID, _ localName: String?) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            next.users[index].localName = localName
            next.users[index].usesProvisionalName = false
        }
    }

    func storedMembers(in groupID: UUID) -> [GroupSnapshot.Member] {
        snapshot?.groups.first { $0.id == groupID }?.members ?? []
    }

    func setMemberName(_ memberID: String, in groupID: UUID, localName: String?) throws {
        guard let snapshot, memberID != self.localMemberID,
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }),
              let member = snapshot.groups[index].members.firstIndex(where: { $0.id == memberID }),
              localName.map(IntercomGroup.isValidName) ?? true else { throw GroupStorageError.invalidUpdate }
        if let user = snapshot.users.first(where: { $0.memberIDs.contains(memberID)
            || ($0.principal != nil && $0.principal == snapshot.groups[index].accountDevices[memberID]?.principal) }) {
            if let localName { try renameUser(user.id, displayName: localName) } else { try resetUserName(user.id) }
            return
        }
        var groups = try snapshot.groups.map { try $0.group() }
        groups[index].members[member].localName = localName
        try update(groups, credential: nil)
    }

    @discardableResult
    func receiveProfile(_ profile: VerifiedPeerProfile, connectedMemberIDs: Set<String> = []) throws -> Bool {
        let name = profile.displayName, memberID = profile.identity.memberID, groupID = profile.groupID
        guard let snapshot else { throw IntercomGroupError.storageUnavailable }
        guard memberID != localMemberID, IntercomGroup.isValidName(name),
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }),
              snapshot.groups[index].matchesInvitationDeviceKey(profile.identity.publicKey, for: memberID) else { return false }
        var groups = try snapshot.groups.map { try $0.group() }
        var users = snapshot.users
        var principal = profile.identity.principal
        if let user = users.firstIndex(where: { $0.memberIDs.contains(memberID) }) {
            guard users[user].deviceKeys?[memberID] == profile.identity.publicKey,
                  users[user].principal == nil || profile.identity.principal == nil
                    || users[user].principal == profile.identity.principal else { return false }
            users[user].displayName = name
            principal = principal ?? users[user].principal
        }
        if snapshot.groups[index].excludesMember(memberID, principal: principal) { return false }
        if groups[index].accountPair != nil {
            guard groups[index].bindAccountDevice(profile.identity, name: name, localMemberID: localMemberID, retaining: connectedMemberIDs) else { return false }
        } else if groups[index].kind == .group {
            guard groups[index].bindGroupRepresentative(profile.identity, name: name, localMemberID: localMemberID, retaining: connectedMemberIDs) else { return false }
            if let principal = profile.identity.principal, let user = users.firstIndex(where: { $0.principal == principal }) {
                users[user].displayName = name
            }
        } else {
            guard let member = groups[index].members.firstIndex(where: { $0.id == memberID }) else { return false }
            groups[index].members[member].displayName = name
        }
        if groups[index] != (try snapshot.groups[index].group()) || users != snapshot.users {
            try update(groups, credential: nil, users: users)
        }
        return true
    }

    /// You own a regular group you made here; one you joined through an invitation is someone else's.
    func ownsGroup(_ groupID: UUID) -> Bool {
        snapshot?.groups.first { $0.id == groupID }?.joinedByInvitation != true
    }

    var unacknowledgedGroupTabOffers: [UUID] {
        snapshot?.groups.filter { $0.kind == .group && $0.joinedByInvitation == true && $0.groupTabOfferAcknowledged == false }.map(\.id) ?? []
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

    /// A saved person and their direct group are one thing. Removing the person removes
    /// that group and its key in the same commit; regular groups keep the member.
    /// Returns the removed direct groups so a live call to one of them can end.
    @discardableResult
    func removeUser(_ id: UUID) throws -> Set<UUID> {
        guard let snapshot, let user = snapshot.users.first(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        let removed = Set(snapshot.groups.filter { belongs($0, to: user) }.map(\.id))
        try update(snapshot.groups.filter { !removed.contains($0.id) }.map { try $0.group() },
                   credential: nil, users: snapshot.users.filter { $0.id != id }) { next in
            Self.cancelPendingGroupReceipts(in: &next) { record in
                record.senderMemberID.map(user.memberIDs.contains) == true
            }
        }
        return removed
    }

    private func belongs(_ record: GroupSnapshot.Record, to user: SavedUser) -> Bool {
        guard record.kind == .direct else { return false }
        if let principal = user.principal, let pair = record.accountPair,
           let local = localMemberID.flatMap({ record.accountDevices[$0]?.principal }),
           pair.other(than: local) == principal { return true }
        return record.members.contains { $0.id != localMemberID && user.memberIDs.contains($0.id) }
    }

    /// A direct group whose person is no longer saved, as an earlier version left after deleting them.
    private func isOrphanedDirectGroup(_ record: GroupSnapshot.Record, users: [SavedUser]) -> Bool {
        guard record.kind == .direct, record.members.contains(where: { $0.id != localMemberID }) else { return false }
        return !users.contains { belongs(record, to: $0) }
    }

    func hasRetiredGroupLink(_ accepted: AcceptedDirectInvitation) -> Bool {
        snapshot?.hasRetiredGroupLink(accepted.receipt) == true
    }

    func acceptInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String, retainingMemberIDs: Set<String> = [],
                          now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard let snapshot else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot, now: now) { next in
            try self.storeAcceptedInvitation(accepted, inviterName: inviterName, retainingMemberIDs: retainingMemberIDs, in: &next)
        }
    }

    private func storeAcceptedInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String? = nil, retainingMemberIDs: Set<String> = [],
                                         in next: inout GroupSnapshot) throws {
        let receipt = accepted.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.invitation != nil, receipt.proof != nil,
              receipt.inviteeMemberID == localMemberID,
              let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }),
              next.groups[index].members.contains(where: { $0.id == receipt.inviteeMemberID }) else {
            throw GroupStorageError.invalidUpdate
        }
        let name = inviterName ?? next.groups[index].members.first(where: { $0.id == receipt.inviterMemberID })?.displayName
        guard let name, IntercomGroup.isValidName(name) else { throw GroupStorageError.invalidUpdate }
        if next.groups[index].excludesMember(accepted.inviter.memberID, principal: accepted.inviter.principal) {
            throw GroupStorageError.identityConflict
        }
        if next.groups[index].kind == .group, let expiry = receipt.invitation?.expiresAt {
            guard !next.hasRetiredGroupLink(receipt) else { throw GroupInviteTokenError.retiredGroupLink }
            if !next.groupLinkReceipts.contains(where: { $0.groupID == receipt.groupID && $0.receiptID == receipt.id }) {
                next.groupLinkReceipts.append(.init(groupID: receipt.groupID, receiptID: receipt.id, expiresAt: expiry, retired: false))
            }
        }
        if !next.groups[index].receivedInvitationIDs.contains(receipt.id) {
            try next.remember(.init(id: receipt.inviterMemberID, displayName: name), identity: accepted.inviter)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
        if next.groups[index].accountPair != nil || next.groups[index].kind == .group {
            var group = try next.groups[index].group()
            let localPrincipal = localMemberID.flatMap { group.accountDevices[$0]?.principal }
            if group.kind == .group {
                if accepted.inviter.principal == nil || accepted.inviter.principal != localPrincipal {
                    let retainsActiveRepresentative = group.accountDevices.contains { memberID, binding in
                        memberID != accepted.inviter.memberID && binding.principal == accepted.inviter.principal
                            && retainingMemberIDs.contains(memberID)
                    }
                    if !retainsActiveRepresentative {
                        let retained = retainingMemberIDs.union([accepted.inviter.memberID])
                        guard group.bindGroupRepresentative(accepted.inviter, name: name, localMemberID: localMemberID, retaining: retained) else { throw GroupStorageError.identityConflict }
                    }
                }
            } else {
                guard group.bindAccountDevice(accepted.inviter, name: name, localMemberID: localMemberID, retaining: Set(group.members.map(\.id))) else { throw GroupStorageError.identityConflict }
            }
            next.groups[index].members = GroupSnapshot.Record(group).members
            next.groups[index].accountDevices = group.accountDevices
        }
        try next.groups[index].rememberInvitationDevice(accepted.inviter)
        next.groups[index].pendingInvitation = receipt
    }

    func pendingInvitation(for groupID: UUID) -> DirectInvitationReceipt? {
        snapshot?.groups.first { $0.id == groupID }?.pendingInvitation
    }

    func receiveInvitation(_ verified: VerifiedDirectInvitation) throws {
        let receipt = verified.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.inviterMemberID == localMemberID,
              let snapshot, let record = snapshot.groups.first(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
        // Persist receipt IDs even if the contact is later deleted. Retrying an
        // already accepted invitation must not silently recreate that contact.
        guard !record.receivedInvitationIDs.contains(receipt.id) else { return }
        try amend(snapshot) { next in
            guard let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }) else { throw GroupStorageError.invalidUpdate }
            try next.remember(.init(id: receipt.inviteeMemberID, displayName: receipt.displayName), identity: verified.identity)
            try next.groups[index].rememberInvitationDevice(verified.identity)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
    }

    func acknowledgeInvitation(_ receipt: DirectInvitationReceipt) throws {
        guard receipt.kind == .acknowledged, let snapshot,
              let index = snapshot.groups.firstIndex(where: { $0.id == receipt.groupID }),
              let pending = snapshot.groups[index].pendingInvitation,
              pending.id == receipt.id, pending.inviterMemberID == receipt.inviterMemberID,
              pending.inviteeMemberID == receipt.inviteeMemberID,
              pending.invitation == receipt.invitation, pending.proof == receipt.proof,
              let proof = receipt.acknowledgementProof,
              proof.publicKey == pending.invitation?.inviterDeviceKey else { return }
        guard (try? proof.verify(receipt.acknowledgementMessage(), purpose: .acknowledgeInvitation, memberID: receipt.inviterMemberID)) != nil else { return }
        try amend(snapshot) { next in next.groups[index].pendingInvitation = nil }
    }

    private func prepareKey(_ secret: String) throws -> UUID {
        let reference = UUID()
        try credentials.saveSecret(secret, reference: reference)
        guard try credentials.secret(reference: reference) == secret else { throw IntercomGroupError.credentialVerificationFailed }
        return reference
    }

    private func update(_ groups: [IntercomGroup], credential: GroupAccessCredential?, additionalCredentials: [GroupAccessCredential] = [], users: [SavedUser]? = nil,
                        now: TimeInterval = Date().timeIntervalSince1970,
                        modify: (inout GroupSnapshot) throws -> Void = { _ in }) throws {
        guard isWritable, let previous = snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == previous else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        // Validate the requested edit before directory names are reapplied.
        do { for group in groups { _ = try GroupSnapshot.Record(group).group() } }
        catch { throw GroupStorageError.invalidUpdate }
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
           groupRemovalReceipts: previous.groupRemovalReceipts.filter { $0.expiresAt > now })
        try modify(&next)
        let retainedGroupIDs = Set(next.groups.map(\.id))
        for removed in previous.groups where removed.kind == .group && !retainedGroupIDs.contains(removed.id) {
            next.retireGroupLinks(from: removed)
        }
        next.discardExpiredRetiredGroupLinks(now: now)
        reconcileInvitations(in: &next)
        for index in next.groups.indices { next.groups[index].discardInvitationKeysForDepartedMembers() }
        next.synchronizeUserReferences()
        do { _ = try next.encoded() }
        catch { throw GroupStorageError.invalidUpdate }
        let allCredentials = (credential.map { [$0] } ?? []) + additionalCredentials
        for credential in allCredentials {
            guard let index = next.groups.firstIndex(where: { $0.id == credential.groupID }) else { throw GroupStorageError.invalidUpdate }
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

    /// An edit that leaves the groups themselves as they are stored.
    private func amend(_ snapshot: GroupSnapshot, now: TimeInterval = Date().timeIntervalSince1970,
                       _ modify: (inout GroupSnapshot) throws -> Void) throws {
        try update(snapshot.groups.map { try $0.group() }, credential: nil, now: now, modify: modify)
    }

    private func cleanup(_ current: GroupSnapshot) {
        do {
            let live = Set(current.groups.compactMap(\.credentialReference) + current.contactInvitations.compactMap(\.credentialReference) + current.groupDeliveries.compactMap(\.credentialReference))
            for reference in try credentials.references().subtracting(live) { try credentials.delete(reference: reference) }
            try legacy?.cleanup()
            needsCleanup = false
        } catch { needsCleanup = true }
    }

    func reset() throws {
        try store.lock(); defer { store.unlock() }
        // A newer schema must be opened by the matching app, not reset by this one.
        do { _ = try store.read() }
        catch GroupStorageError.unsupportedVersion { throw GroupStorageError.unsupportedVersion }
        catch { /* Preserve malformed bytes before replacing them. */ }
        try store.archive(legacyData: legacy?.archiveData())
        let empty = GroupSnapshot()
        try store.commit(empty)
        guard try store.read() == empty else { isWritable = false; throw GroupStorageError.verificationFailed }
        snapshot = empty; isWritable = true; missingCredentialGroupIDs = []
        cleanup(empty)
    }
}

extension GroupRepository {
    func stageContactInvitation(_ token: GroupInviteToken, now: TimeInterval, replacingExpiredInvitation id: UUID? = nil, personID: UUID? = nil) throws {
        try token.validate(contactBootstrap: true)
        guard let snapshot, let context = token.directInvitation?.context,
              token.inviterMemberID == localMemberID, !token.isExpired(now: now), token.verifySignature(),
              !snapshot.contactInvitations.contains(where: { $0.id == context.id }) else { throw GroupStorageError.invalidUpdate }
        guard let proof = token.identityProof else { throw GroupStorageError.invalidUpdate }
        _ = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: token.inviterMemberID)
        let previous = id.flatMap { id in snapshot.contactInvitations.first { $0.id == id } }
        if id != nil {
            guard let previous, previous.isExpiredTombstone
                    || (previous.direction == .outgoing && previous.state == .pending && previous.expiresAt <= now) else {
                throw GroupStorageError.invalidUpdate
            }
        }
        let personID = personID ?? previous?.personID
        if let personID {
            guard snapshot.users.contains(where: { $0.id == personID && !$0.isRegistered }) else { throw GroupStorageError.invalidUpdate }
            guard !snapshot.contactInvitations.contains(where: { $0.personID == personID && $0.id != id && $0.state == .pending && $0.expiresAt > now }) else {
                throw GroupStorageError.invalidUpdate
            }
        }
        if let target = token.invitedGroup {
            guard personID != nil, let group = snapshot.groups.first(where: { $0.id == target.id }), group.kind == .group,
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
                expiresAt: context.expiresAt, credentialReference: reference, nickname: previous?.nickname ?? snapshot.users.first(where: { $0.id == personID })?.resolvedDisplayName, sent: false, personID: personID, invitedGroupID: token.invitedGroup?.id))
            if let target = token.invitedGroup, let index = next.groups.firstIndex(where: { $0.id == target.id }) {
                if let previous { next.groups[index].members.removeAll { $0.id == previous.pendingGroupMemberID } }
                guard next.groups[index].members.count < IntercomGroup.maximumMemberCount else { throw GroupStorageError.invalidUpdate }
                let record = next.contactInvitations[next.contactInvitations.count - 1]
                next.groups[index].members.append(.init(id: record.pendingGroupMemberID, displayName: record.nickname ?? "Invitation"))
            }
        }
    }

    /// A selection of new people and its group is one operation, including every reserved slot.
    func saveGroupInvitationSelection(_ group: IntercomGroup, credential: GroupAccessCredential,
                                     invitees: [(person: SavedUser, token: GroupInviteToken)], now: TimeInterval,
                                     selectedUsers: Set<UUID>, deliveries: [GroupDeliveryRecord]) throws {
        guard let snapshot, group.kind == .group, credential.groupID == group.id, !invitees.isEmpty,
              group.members.count + invitees.count <= IntercomGroup.maximumMemberCount,
              Set(invitees.map { $0.person.id }).count == invitees.count else { throw GroupStorageError.invalidUpdate }
        if snapshot.groups.contains(where: { $0.id == group.id }) {
            guard try self.credential(for: group.id)?.secret == credential.secret else { throw GroupStorageError.identityConflict }
        }
        var reserved = group
        for (person, token) in invitees {
            try token.validate(contactBootstrap: true)
            guard let context = token.directInvitation?.context, let target = token.invitedGroup,
                  target.id == group.id, target.name == group.name, target.secret == credential.secret,
                  token.inviterMemberID == localMemberID, !token.isExpired(now: now), token.verifySignature(),
                  !person.isRegistered, IntercomGroup.isValidName(person.resolvedDisplayName),
                  !snapshot.users.contains(where: { $0.id == person.id }),
                  !snapshot.contactInvitations.contains(where: { $0.id == context.id }), let proof = token.identityProof else { throw GroupStorageError.invalidUpdate }
            _ = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: token.inviterMemberID)
            reserved.members.append(.init(id: GroupMember.pendingInvitePrefix + "contact-" + context.id.uuidString.lowercased(), displayName: person.resolvedDisplayName))
        }
        try update([reserved] + snapshot.groups.filter { $0.id != group.id }.map { try $0.group() }, credential: credential) { next in
            Self.restoreExplicitlySelectedMembers(selectedUsers, in: group.id, snapshot: &next)
            try self.appendGroupDeliveries(deliveries, to: &next)
            for (person, token) in invitees {
                guard let context = token.directInvitation?.context else { throw GroupStorageError.invalidUpdate }
                next.users.append(person)
                next.contactInvitations.append(.init(id: context.id, direction: .outgoing, expiresAt: context.expiresAt,
                    credentialReference: try self.prepareKey(ContactInvitationPayload(token: token).encodedSecret()),
                    nickname: person.resolvedDisplayName, sent: false, personID: person.id, invitedGroupID: group.id))
            }
        }
    }

    private func appendGroupDeliveries(_ records: [GroupDeliveryRecord], to next: inout GroupSnapshot) throws {
        for record in records {
            guard record.isValid, record.direction == .outgoing, record.state == .pending, record.credentialReference == nil,
                  !next.groupDeliveries.contains(where: { $0.id == record.id }),
                  let group = next.groups.first(where: { $0.id == record.groupID && $0.kind == .group }),
                  let user = next.users.first(where: { $0.principal == record.recipient && $0.memberIDs.contains(record.recipientMemberID)
                      && $0.deviceKeys?[record.recipientMemberID] == record.recipientKey }),
                  isSelectedGroupDeliveryRecipient(user, in: group) else { throw GroupStorageError.invalidUpdate }
            next.groupDeliveries.append(record)
        }
    }

    private func isSelectedGroupDeliveryRecipient(_ user: SavedUser, in group: GroupSnapshot.Record) -> Bool {
        group.members.contains { user.memberIDs.contains($0.id) }
            || group.accountDevices.values.contains { $0.principal == user.principal }
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

    func saveGroupDeliveryEnvelope(_ envelope: GroupInvitationEnvelope) throws {
        guard let snapshot, let old = snapshot.groupDeliveries.first(where: { $0.id == envelope.id }),
              old.direction == .outgoing, old.state == .pending, old.credentialReference == nil,
              old.recipient == envelope.recipient, old.recipientMemberID == envelope.recipientMemberID,
              old.recipientKey == envelope.recipientKey, old.expiresAt == envelope.expiresAt,
              envelope.senderMemberID == localMemberID else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            guard let index = next.groupDeliveries.firstIndex(where: { $0.id == envelope.id }) else { throw GroupStorageError.invalidUpdate }
            next.groupDeliveries[index].credentialReference = try self.prepareKey(String(decoding: JSONEncoder().encode(envelope), as: UTF8.self))
        }
    }
    func groupDeliveryEnvelope(_ id: UUID) throws -> GroupInvitationEnvelope {
        guard isWritable, let snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == snapshot else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        guard let record = snapshot.groupDeliveries.first(where: { $0.id == id }), record.state == .pending || record.state == .queued,
              let reference = record.credentialReference, let value = try credentials.secret(reference: reference),
              let data = value.data(using: .utf8) else { throw GroupStorageError.invalidUpdate }
        let envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: data)
        guard envelope.id == id, envelope.recipient == record.recipient, envelope.recipientKey == record.recipientKey,
              envelope.recipientMemberID == record.recipientMemberID, envelope.expiresAt == record.expiresAt else { throw GroupStorageError.identityConflict }
        return envelope
    }
    func setGroupDeliveryState(_ id: UUID, state: GroupDeliveryRecord.State) throws {
        guard let snapshot, let old = snapshot.groupDeliveries.first(where: { $0.id == id }), old.direction == .outgoing,
              (old.state == .pending || old.state == .queued), state != .pending,
              state != .queued || old.credentialReference != nil else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            guard let index = next.groupDeliveries.firstIndex(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
            next.groupDeliveries[index].state = state
            if state == .received || state == .cancelled { next.groupDeliveries[index].credentialReference = nil }
        }
    }
    func removeFinishedGroupDeliveries(now: TimeInterval, cancelledID: UUID? = nil) throws {
        guard let snapshot else { throw IntercomGroupError.storageUnavailable }
        guard snapshot.groupDeliveries.contains(where: { $0.expiresAt <= now || ($0.id == cancelledID && $0.state == .cancelled) }) else { return }
        try amend(snapshot) { next in next.groupDeliveries.removeAll { $0.expiresAt <= now || ($0.id == cancelledID && $0.state == .cancelled) } }
    }

    private static func cancelPendingGroupReceipts(in next: inout GroupSnapshot, matching: (GroupDeliveryRecord) -> Bool) {
        for index in next.groupDeliveries.indices {
            let record = next.groupDeliveries[index]
            guard record.direction == .incoming, record.state == .pending, matching(record) else { continue }
            next.groupDeliveries[index].state = .cancelled
            next.groupDeliveries[index].credentialReference = nil
            next.groupDeliveries[index].senderMemberID = nil
        }
    }

    func cancelPendingGroupReceipt(_ id: UUID) throws {
        guard let snapshot, snapshot.groupDeliveries.contains(where: { $0.id == id && $0.direction == .incoming && $0.state == .pending })
        else { return }
        try amend(snapshot) { next in Self.cancelPendingGroupReceipts(in: &next) { $0.id == id } }
    }

    func stageGroupDelivery(_ envelope: GroupInvitationEnvelope, token: GroupInviteToken, now: TimeInterval) throws -> GroupDeliveryRecord.State {
        let (_, identity, snapshot) = try validateIncomingGroupDelivery(envelope, token: token, now: now)
        let old = snapshot.groupDeliveries.first(where: { $0.id == envelope.id })
        if let old {
            guard old.direction == .incoming, old.groupID == token.groupID, old.recipient == envelope.recipient,
                  old.recipientMemberID == envelope.recipientMemberID, old.recipientKey == envelope.recipientKey,
                  old.expiresAt == envelope.expiresAt else { throw GroupStorageError.identityConflict }
            if old.state != .pending { return old.state }
        }
        let target = ContactGroupInvitation(id: token.groupID, name: token.groupName, secret: token.groupSecret)
        let existing = snapshot.groups.first(where: { $0.id == token.groupID })
        if let existing, try !matchesGroupDelivery(target, sender: identity, principal: envelope.sender, existing: existing) {
            if old != nil { try cancelPendingGroupReceipt(envelope.id) }
            return .cancelled
        }
        if old != nil { return .pending }
        guard existing != nil || snapshot.groups.count < 256 else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            let packet = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
            next.groupDeliveries.append(.init(id: envelope.id, noticeID: envelope.id, groupID: token.groupID,
                recipient: envelope.recipient, recipientMemberID: envelope.recipientMemberID, recipientKey: envelope.recipientKey,
                expiresAt: envelope.expiresAt, direction: .incoming, state: .pending,
                credentialReference: try self.prepareKey(packet), senderMemberID: envelope.senderMemberID))
        }
        return .pending
    }

    @discardableResult
    func receiveGroupDelivery(_ envelope: GroupInvitationEnvelope, token: GroupInviteToken, localDisplayName: String, now: TimeInterval) throws -> IntercomGroup? {
        guard let snapshot, let index = snapshot.groupDeliveries.firstIndex(where: { $0.id == envelope.id }),
              snapshot.groupDeliveries[index].direction == .incoming else { throw GroupStorageError.invalidUpdate }
        let record = snapshot.groupDeliveries[index]
        // A local deletion can cancel the staged record while the network request is in flight.
        guard record.state == .pending else { return nil }
        let (user, identity, _) = try validateIncomingGroupDelivery(envelope, token: token, now: now)
        guard let localMemberID, record.groupID == token.groupID,
              record.recipient == envelope.recipient, record.recipientKey == envelope.recipientKey,
              record.senderMemberID == envelope.senderMemberID, record.expiresAt == envelope.expiresAt
        else { throw GroupStorageError.invalidUpdate }
        let target = ContactGroupInvitation(id: token.groupID, name: token.groupName, secret: token.groupSecret)
        let existing = snapshot.groups.first(where: { $0.id == target.id })
        if let existing, try !matchesGroupDelivery(target, sender: identity, principal: envelope.sender, existing: existing) {
            // A manual join, local save or removal can race with the Worker receipt.
            try cancelPendingGroupReceipt(envelope.id)
            return nil
        }
        let previous = try snapshot.groups.map { try $0.group() }
        let newGroup = existing == nil
        let groups = newGroup ? try groupsByJoining(target, inviter: .init(id: envelope.senderMemberID, displayName: user.displayName),
            identity: identity, localDisplayName: localDisplayName, groups: previous) : previous
        try update(groups, credential: newGroup ? .init(groupID: token.groupID, secret: token.groupSecret) : nil) { next in
            if let groupIndex = next.groups.firstIndex(where: { $0.id == token.groupID }) {
                if newGroup {
                    next.groups[groupIndex].joinedByInvitation = true
                    next.groups[groupIndex].groupTabOfferAcknowledged = false
                    next.groups[groupIndex].accountDevices[localMemberID] = .init(principal: envelope.recipient, publicKey: envelope.recipientKey)
                    next.groups[groupIndex].accountDevices[envelope.senderMemberID] = .init(principal: envelope.sender, publicKey: identity.publicKey)
                }
                try next.groups[groupIndex].rememberInvitationDevice(identity)
            }
            next.groupDeliveries[index].state = .received
            next.groupDeliveries[index].credentialReference = nil
            next.groupDeliveries[index].senderMemberID = nil
        }
        return storedGroup(token.groupID)
    }

    private func validateIncomingGroupDelivery(_ envelope: GroupInvitationEnvelope, token: GroupInviteToken,
                                               now: TimeInterval) throws -> (SavedUser, VerifiedDeviceProof, GroupSnapshot) {
        try token.validate()
        guard let snapshot, envelope.expiresAt > now, token.expiresAt == envelope.expiresAt,
              token.verifySignature(), token.inviterMemberID == envelope.senderMemberID,
              token.recipientMemberID == nil, token.directInvitation?.context.contactBootstrap != true,
              let proof = token.identityProof, proof.publicKey == envelope.proof?.publicKey,
              token.groupID != IntercomGroup.directCallID(memberIDs: [envelope.senderMemberID, envelope.recipientMemberID]),
              let localMemberID, localMemberID == envelope.recipientMemberID,
              let user = snapshot.users.first(where: { $0.principal == envelope.sender && $0.memberIDs.contains(envelope.senderMemberID)
                  && $0.deviceKeys?[envelope.senderMemberID] == envelope.proof?.publicKey }) else { throw GroupStorageError.invalidUpdate }
        let identity = try proof.verify(Data(token.signature.utf8), purpose: .issueInvitation, memberID: envelope.senderMemberID)
        return (user, identity, snapshot)
    }

    func acceptContactInvitation(_ token: GroupInviteToken, accepted: AcceptedDirectInvitation,
                                 localDisplayName: String, now: TimeInterval) throws {
        try token.validate(contactBootstrap: true)
        guard let snapshot, let context = token.directInvitation?.context,
              accepted.receipt.invitation == context, accepted.receipt.inviteeMemberID == localMemberID,
              accepted.inviter.memberID == token.inviterMemberID, !token.isExpired(now: now) else { throw GroupStorageError.invalidUpdate }
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
        let joiningGroups = try groupsByJoining(token.invitedGroup, inviter: inviter, identity: accepted.inviter, localDisplayName: localDisplayName, groups: call.groups)
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
                personID: next.users.first(where: { $0.memberIDs.contains(accepted.inviter.memberID) })?.id, invitedGroupID: token.invitedGroup?.id))
        }
    }

    func confirmContactInvitation(_ verified: VerifiedDirectInvitation, localDisplayName: String, now: TimeInterval, receivedBySharing: Bool = false) throws {
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
            guard let index = next.contactInvitations.firstIndex(where: { $0.id == context.id }) else { throw GroupStorageError.invalidUpdate }
            let alreadyKnown = next.users.contains { $0.memberIDs.contains(recipient.id)
                || (verified.identity.principal != nil && $0.principal == verified.identity.principal) }
            try self.rememberContactDevice(recipient, identity: verified.identity, now: now, in: &next)
            if let personID = old.personID, let placeholder = next.users.first(where: { $0.id == personID && !$0.isRegistered }),
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
            if let targetID = old.invitedGroupID {
                guard let groupIndex = next.groups.firstIndex(where: { $0.id == targetID && $0.kind == .group }),
                      let slot = next.groups[groupIndex].members.firstIndex(where: { $0.id == old.pendingGroupMemberID }) else { throw GroupStorageError.invalidUpdate }
                next.groups[groupIndex].reinstateMembers {
                    $0.matches(recipient.id, principal: verified.identity.principal)
                }
                let alreadyMember = next.groups[groupIndex].members.contains { $0.id == recipient.id }
                    || (verified.identity.principal.map { principal in next.groups[groupIndex].accountDevices.values.contains { $0.principal == principal } } ?? false)
                if alreadyMember { next.groups[groupIndex].members.remove(at: slot) }
                else {
                    next.groups[groupIndex].members[slot] = .init(id: recipient.id, displayName: recipient.displayName)
                    if let principal = verified.identity.principal { next.groups[groupIndex].accountDevices[recipient.id] = .init(principal: principal, publicKey: verified.identity.publicKey) }
                }
                try next.groups[groupIndex].rememberInvitationDevice(verified.identity)
            }
            next.contactInvitations[index].credentialReference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations[index].state = .confirmed
            next.contactInvitations[index].receivedBySharing = receivedBySharing ? true : nil
            next.contactInvitations[index].receiptID = receipt.id
            next.contactInvitations[index].peerMemberID = verified.identity.memberID
            next.contactInvitations[index].peerDeviceKey = verified.identity.publicKey
        }
    }

    private func groupsByJoining(_ target: ContactGroupInvitation?, inviter: GroupMember, identity: VerifiedDeviceProof,
                                 localDisplayName: String, groups: [IntercomGroup]) throws -> [IntercomGroup] {
        guard let target else { return groups }
        if let existing = groups.first(where: { $0.id == target.id }) {
            guard try matchesSavedGroup(target, kind: existing.kind) else { throw GroupStorageError.identityConflict }
            return groups
        }
        guard let localMemberID else { throw GroupStorageError.invalidUpdate }
        let devices: [String: AccountDeviceBinding] = identity.principal.map { [inviter.id: .init(principal: $0, publicKey: identity.publicKey)] } ?? [:]
        let group = try IntercomGroup(id: target.id, name: target.name,
            members: [.init(id: localMemberID, displayName: localDisplayName), inviter], accountDevices: devices)
        return [group] + groups
    }

    private func matchesSavedGroup(_ target: ContactGroupInvitation, kind: IntercomGroup.Kind) throws -> Bool {
        guard kind == .group else { return false }
        // A missing or unreadable local credential may be recoverable.
        guard let saved = try credential(for: target.id) else { throw GroupStorageError.identityConflict }
        return saved.secret == target.secret
    }

    private func matchesGroupDelivery(_ target: ContactGroupInvitation, sender: VerifiedDeviceProof,
                                      principal: AccountPrincipal, existing: GroupSnapshot.Record) throws -> Bool {
        guard !existing.excludesMember(sender.memberID, principal: principal),
              existing.matchesInvitationDeviceKey(sender.publicKey, for: sender.memberID),
              existing.accountDevices[sender.memberID].map({ $0.publicKey == sender.publicKey }) ?? true else { return false }
        return try matchesSavedGroup(target, kind: existing.kind ?? .group)
    }

    private func reconcileInvitations(in next: inout GroupSnapshot) {
        // Append order identifies the latest invitation even when the device clock changes.
        var latestNotices: [UUID: [AccountPrincipal: UUID]] = [:]
        for record in next.groupDeliveries where record.direction == .outgoing {
            latestNotices[record.groupID, default: [:]][record.recipient] = record.noticeID
        }
        next.groupDeliveries.removeAll { record in
            record.direction == .outgoing && record.state == .received
                && latestNotices[record.groupID]?[record.recipient] != record.noticeID
        }
        for index in next.groupDeliveries.indices {
            let record = next.groupDeliveries[index]
            guard record.direction == .outgoing, record.state == .pending || record.state == .queued else { continue }
            let group = next.groups.first(where: { $0.id == record.groupID && $0.kind == .group })
            let user = next.users.first { $0.principal == record.recipient && $0.memberIDs.contains(record.recipientMemberID)
                && $0.deviceKeys?[record.recipientMemberID] == record.recipientKey }
            let remainsSelected = group.flatMap { group in user.map { isSelectedGroupDeliveryRecipient($0, in: group) } } ?? false
            if !remainsSelected {
                next.groupDeliveries[index].state = .cancelled
                next.groupDeliveries[index].credentialReference = nil
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
                record.direction == .incoming || next.groups[index].members.contains { $0.id == record.pendingGroupMemberID }
            } == true
            if !hasPerson || (record.state == .pending && !targetExists) {
                next.contactInvitations[index].state = .cancelled
                next.contactInvitations[index].credentialReference = nil
            }
            if record.direction == .outgoing, next.contactInvitations[index].state == .cancelled, let group {
                next.groups[group].members.removeAll { $0.id == record.pendingGroupMemberID }
            }
        }
        var pendingByGroup: [UUID: Set<UUID>] = [:]
        for invitation in next.contactInvitations where invitation.direction == .outgoing && invitation.state == .pending {
            if let group = invitation.invitedGroupID { pendingByGroup[group, default: []].insert(invitation.id) }
        }
        for index in next.groups.indices {
            let groupID = next.groups[index].id
            next.groups[index].discardRemovalHistory(withPendingInvitations: pendingByGroup[groupID] ?? [])
        }
    }

    /// A contact invitation completes the pair call in the same commit as the user.
    /// Both sides derive one call key from the invitation secret they already share,
    /// so a nearby call needs no later key exchange or Internet service. A
    /// re-invitation replaces an earlier key on both sides.
    private func contactDirectCall(with remote: GroupMember, localDisplayName: String, token: GroupInviteToken,
                                   groups: [IntercomGroup]) throws -> (groups: [IntercomGroup], credential: GroupAccessCredential) {
        guard let localMemberID else { throw GroupStorageError.invalidUpdate }
        let members = [GroupMember(id: localMemberID, displayName: localDisplayName), remote]
        let id = IntercomGroup.directCallID(memberIDs: members.map(\.id))
        let call = try groups.first { $0.id == id } ?? IntercomGroup(id: id, name: "Direct Call", members: members, kind: .direct)
        guard call.kind == .direct else { throw GroupStorageError.identityConflict }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.groupSecret.utf8)),
            salt: Data("rideintercom.contact-direct-call.v1".utf8), info: Data(id.uuidString.utf8), outputByteCount: 32)
        let secret = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return ([call] + groups.filter { $0.id != id }, .init(groupID: id, secret: secret))
    }

    func contactInvitationPayload(_ id: UUID) throws -> ContactInvitationPayload {
        guard isWritable, let snapshot else { throw IntercomGroupError.storageUnavailable }
        try store.lock(); defer { store.unlock() }
        guard try store.read() == snapshot else { isWritable = false; throw GroupStorageError.changedByAnotherProcess }
        guard let record = snapshot.contactInvitations.first(where: { $0.id == id }), record.canResume,
              let reference = record.credentialReference, let secret = try credentials.secret(reference: reference) else { throw GroupStorageError.invalidUpdate }
        let payload = try ContactInvitationPayload.decodeSecret(secret, record: record)
        guard (record.direction == .outgoing) == (payload.token.inviterMemberID == localMemberID) else { throw GroupStorageError.identityConflict }
        return payload
    }

    func removeExpiredContactInvitations(now: TimeInterval) throws {
        guard now.isFinite, let snapshot else { throw GroupStorageError.invalidUpdate }
        guard snapshot.contactInvitations.contains(where: { $0.expiresAt <= now && $0.state != .expired }) else { return }
        try amend(snapshot) { next in
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
        }
    }

    func completeContactNotification(_ id: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .incoming, record.state == .pending else { throw GroupStorageError.invalidUpdate }
        try setContactInvitationState(id, state: .delivered)
    }

    func cancelContactInvitation(_ id: UUID) throws {
        try setContactInvitationState(id, state: .cancelled)
    }

    /// A share destination took the link: the invitation now waits to be accepted.
    func markContactInvitationSent(_ id: UUID) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .outgoing, record.state == .pending else { throw GroupStorageError.invalidUpdate }
        guard record.sent == false else { return }
        try amendContactInvitation(id, in: snapshot) { record in record.sent = true }
    }

    /// Names an outgoing invitation before it completes; nil clears the name.
    func setContactInvitationNickname(_ id: UUID, nickname: String?) throws {
        guard let snapshot, let record = snapshot.contactInvitations.first(where: { $0.id == id }),
              record.direction == .outgoing, record.state == .pending else { throw GroupStorageError.invalidUpdate }
        guard record.nickname != nickname else { return }
        try amendContactInvitation(id, in: snapshot) { record in record.nickname = nickname }
    }

    private func amendContactInvitation(_ id: UUID, in snapshot: GroupSnapshot,
                                        _ change: (inout ContactInvitationRecord) -> Void) throws {
        try amend(snapshot) { next in
            guard let index = next.contactInvitations.firstIndex(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
            change(&next.contactInvitations[index])
        }
    }

    private func setContactInvitationState(_ id: UUID, state: ContactInvitationRecord.State) throws {
        guard let snapshot, snapshot.contactInvitations.contains(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        try amendContactInvitation(id, in: snapshot) { record in
            record.state = state
            record.credentialReference = nil
        }
    }
}
