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

    init(store: GroupStoring, credentials: GroupCredentialStoring, legacy: LegacyGroupReader? = nil) {
        self.store = store; self.credentials = credentials; self.legacy = legacy
    }

    func load(localMemberID: String) throws -> [IntercomGroup] {
        self.localMemberID = localMemberID
        try store.lock(); defer { store.unlock() }
        do {
            var current = try store.read() ?? migrate(localMemberID: localMemberID)
            _ = try validateIdentity(current, localMemberID: localMemberID)
            if current.version < 10 {
                current = current.upgraded()
                try store.commit(current)
                guard try store.read() == current else { throw GroupStorageError.verificationFailed }
            }
            // Loading happens with no call running, so a leftover direct group can go now.
            if current.groups.contains(where: { isOrphanedDirectGroup($0, users: current.users) }) {
                current.groups.removeAll { isOrphanedDirectGroup($0, users: current.users) }
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

    func save(_ groups: [IntercomGroup]) throws { try update(groups, credential: nil) }
    func save(_ groups: [IntercomGroup], credential: GroupAccessCredential, acceptedInvitation: AcceptedDirectInvitation? = nil, inviterName: String? = nil) throws {
        let previousGroupIDs = Set(snapshot?.groups.map(\.id) ?? [])
        try update(groups, credential: credential) { next in
            if let receipt = acceptedInvitation {
                try self.storeAcceptedInvitation(receipt, inviterName: inviterName, in: &next)
                // Joined through someone's invitation: they own a regular group, and you can only leave it.
                if let index = next.groups.firstIndex(where: { $0.id == receipt.receipt.groupID }), next.groups[index].kind != .direct,
                   previousGroupIDs.contains(receipt.receipt.groupID) == false {
                    next.groups[index].joinedByInvitation = true
                }
            }
        }
    }
    func delete(_ id: UUID, remaining: [IntercomGroup]) throws { try update(remaining, credential: nil) }

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

    func saveContactPerson(_ id: UUID, name: String) throws {
        guard let snapshot, IntercomGroup.isValidName(name), !snapshot.users.contains(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            next.users.append(SavedUser(id: id, displayName: name, memberIDs: [], localName: name))
        }
    }

    func renameUser(_ id: UUID, displayName: String) throws {
        guard IntercomGroup.isValidName(displayName) else { throw GroupStorageError.invalidUpdate }
        try setUserLocalName(id, displayName)
    }

    func resetUserName(_ id: UUID) throws { try setUserLocalName(id, nil) }

    private func setUserLocalName(_ id: UUID, _ localName: String?) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }) else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in next.users[index].localName = localName }
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
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }) else { return false }
        var groups = try snapshot.groups.map { try $0.group() }
        var users = snapshot.users
        if let user = users.firstIndex(where: { $0.memberIDs.contains(memberID) }) {
            guard users[user].deviceKeys?[memberID] == profile.identity.publicKey,
                  users[user].principal == nil || profile.identity.principal == nil
                    || users[user].principal == profile.identity.principal else { return false }
            users[user].displayName = name
        }
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
            for index in next.contactInvitations.indices where next.contactInvitations[index].personID == id {
                if next.contactInvitations[index].state == .pending {
                    next.contactInvitations[index].state = .cancelled
                    next.contactInvitations[index].credentialReference = nil
                }
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

    func acceptInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String, retainingMemberIDs: Set<String> = []) throws {
        guard let snapshot else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot) { next in
            try self.storeAcceptedInvitation(accepted, inviterName: inviterName, retainingMemberIDs: retainingMemberIDs, in: &next)
        }
    }

    private func storeAcceptedInvitation(_ accepted: AcceptedDirectInvitation, inviterName: String? = nil, retainingMemberIDs: Set<String> = [], in next: inout GroupSnapshot) throws {
        let receipt = accepted.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.invitation != nil, receipt.proof != nil,
              receipt.inviteeMemberID == localMemberID,
              let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }),
              next.groups[index].members.contains(where: { $0.id == receipt.inviteeMemberID }) else {
            throw GroupStorageError.invalidUpdate
        }
        let name = inviterName ?? next.groups[index].members.first(where: { $0.id == receipt.inviterMemberID })?.displayName
        guard let name, IntercomGroup.isValidName(name) else { throw GroupStorageError.invalidUpdate }
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

    private func update(_ groups: [IntercomGroup], credential: GroupAccessCredential?, users: [SavedUser]? = nil,
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
            return record
        }, users: users ?? previous.users, contactInvitations: previous.contactInvitations)
        try modify(&next)
        next.synchronizeUserReferences()
        do { _ = try next.encoded() }
        catch { throw GroupStorageError.invalidUpdate }
        if let credential {
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
        if let credential { missingCredentialGroupIDs.remove(credential.groupID) }
        cleanup(next)
    }

    /// An edit that leaves the groups themselves as they are stored.
    private func amend(_ snapshot: GroupSnapshot, _ modify: (inout GroupSnapshot) throws -> Void) throws {
        try update(snapshot.groups.map { try $0.group() }, credential: nil, modify: modify)
    }

    private func cleanup(_ current: GroupSnapshot) {
        do {
            let live = Set(current.groups.compactMap(\.credentialReference) + current.contactInvitations.compactMap(\.credentialReference))
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
        let payload = ContactInvitationPayload(token: token)
        try amend(snapshot) { next in
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
            // The old record, its name and the new credential change at the manifest's sole commit point.
            if let id { next.contactInvitations.removeAll { $0.id == id } }
            let reference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations.append(.init(id: context.id, direction: .outgoing,
                expiresAt: context.expiresAt, credentialReference: reference, nickname: previous?.nickname ?? snapshot.users.first(where: { $0.id == personID })?.resolvedDisplayName, sent: false, personID: personID))
        }
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
        try update(call.groups, credential: call.credential) { next in
            ContactInvitationRecord.expire(&next.contactInvitations, now: now)
            try next.remember(inviter, identity: accepted.inviter)
            let reference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations.append(.init(id: context.id, direction: .incoming, expiresAt: context.expiresAt,
                credentialReference: reference, receiptID: accepted.receipt.id,
                peerMemberID: accepted.inviter.memberID, peerDeviceKey: accepted.inviter.publicKey,
                personID: next.users.first(where: { $0.memberIDs.contains(accepted.inviter.memberID) })?.id))
        }
    }

    func confirmContactInvitation(_ verified: VerifiedDirectInvitation, localDisplayName: String, now: TimeInterval) throws {
        let receipt = verified.receipt
        guard let snapshot, let context = receipt.invitation, context.contactBootstrap == true,
              receipt.inviterMemberID == localMemberID, now < context.expiresAt,
              let old = snapshot.contactInvitations.first(where: { $0.id == context.id }),
              old.direction == .outgoing, old.canResume else { throw GroupStorageError.invalidUpdate }
        if old.state == .confirmed {
            guard old.receiptID == receipt.id, old.peerMemberID == verified.identity.memberID,
                  old.peerDeviceKey == verified.identity.publicKey else { throw GroupStorageError.identityConflict }
            return
        }
        var payload = try contactInvitationPayload(context.id)
        guard payload.token.directInvitation?.context == context else { throw GroupStorageError.identityConflict }
        payload.receipt = receipt
        let recipient = GroupMember(id: verified.identity.memberID, displayName: receipt.displayName)
        let call = try contactDirectCall(with: recipient, localDisplayName: localDisplayName, token: payload.token,
                                         groups: try snapshot.groups.map { try $0.group() })
        try update(call.groups, credential: call.credential) { next in
            guard let index = next.contactInvitations.firstIndex(where: { $0.id == context.id }) else { throw GroupStorageError.invalidUpdate }
            let alreadyKnown = next.users.contains { $0.memberIDs.contains(recipient.id)
                || (verified.identity.principal != nil && $0.principal == verified.identity.principal) }
            try next.remember(recipient, identity: verified.identity)
            if let personID = old.personID, let placeholder = next.users.first(where: { $0.id == personID && !$0.isRegistered }),
               let registered = next.users.firstIndex(where: { $0.memberIDs.contains(recipient.id) }) {
                // A newly verified person inherits the original local ID and name. An already known
                // identity keeps its ID; the completed exchange resolves an open draft to that person.
                if !alreadyKnown { next.users[registered].id = personID }
                next.users[registered].localName = next.users[registered].localName ?? placeholder.localName
                next.users.removeAll { $0.id == placeholder.id && !$0.isRegistered }
            }
            if let nickname = old.nickname,
               let user = next.users.firstIndex(where: { $0.memberIDs.contains(recipient.id) }),
               next.users[user].localName == nil {
                next.users[user].localName = nickname
            }
            next.contactInvitations[index].credentialReference = try self.prepareKey(payload.encodedSecret())
            next.contactInvitations[index].state = .confirmed
            next.contactInvitations[index].receiptID = receipt.id
            next.contactInvitations[index].peerMemberID = verified.identity.memberID
            next.contactInvitations[index].peerDeviceKey = verified.identity.publicKey
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
