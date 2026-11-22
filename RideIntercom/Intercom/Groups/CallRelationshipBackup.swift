import Foundation

/// Names and stable identifiers for finding restore candidates. These records cannot grant call access.
struct CallRelationshipBackup: Codable, Equatable {
    struct Group: Codable, Equatable {
        let id: UUID
        let name: String
    }

    struct Contact: Codable, Equatable {
        let id: UUID
        let principal: AccountPrincipal
        let restoreRecipientFingerprint: String?

        fileprivate var hasValidRestoreRecipientFingerprint: Bool {
            guard let fingerprint = restoreRecipientFingerprint else { return true }
            guard let bytes = IdentityEncoding.decode(fingerprint), bytes.count == 32 else { return false }
            return IdentityEncoding.encode(bytes) == fingerprint
        }
    }

    private static let currentVersion = 1
    let version: Int
    let owner: AccountPrincipal
    let groups: [Group]
    let contacts: [Contact]

    var isEmpty: Bool { groups.isEmpty && contacts.isEmpty }

    fileprivate init(owner: AccountPrincipal, groups: [Group], contacts: [Contact]) {
        version = Self.currentVersion
        self.owner = owner
        self.groups = groups
        self.contacts = contacts
    }

    static func read(_ data: Data, as signer: DeviceIdentitySigner, now: TimeInterval) throws -> Self {
        let owner = try verifiedOwner(of: signer, now: now)
        return try JSONDecoder().decode(Self.self, from: data).validated(for: owner)
    }

    func validated(for verifiedOwner: AccountPrincipal) throws -> Self {
        guard owner == verifiedOwner else { throw GroupStorageError.identityConflict }
        guard version == Self.currentVersion,
              Set(groups.map(\.id)).count == groups.count,
              Set(contacts.map(\.id)).count == contacts.count,
              Set(contacts.map(\.principal)).count == contacts.count,
              groups.allSatisfy({ IntercomGroup.isValidName($0.name) }),
              contacts.allSatisfy({ contact in
                  contact.principal.isValid && contact.principal.issuer == owner.issuer
                      && contact.principal != owner && contact.hasValidRestoreRecipientFingerprint
              }) else { throw GroupStorageError.invalidUpdate }
        return self
    }

    static func verifiedOwner(
        of signer: DeviceIdentitySigner, now: TimeInterval
    ) throws -> AccountPrincipal {
        guard let identity = signer.identity, identity.expiresAt > now,
              let owner = signer.principal, owner.isValid else { throw GroupStorageError.identityConflict }
        return owner
    }
}

private extension GroupSnapshot {
    func backupCandidate(memberID: String, binding: AccountDeviceBinding) throws -> CallRelationshipBackup {
        let owner = binding.principal
        let owned = groups.filter { record in
            record.pendingInvitation == nil && record.accountDevices[memberID] == binding
                && !record.excludesMember(memberID, principal: owner)
        }
        let calls = Dictionary(uniqueKeysWithValues: owned.map { ($0.id, $0) })
        let contacts = try users.compactMap { user -> CallRelationshipBackup.Contact? in
            guard user.isRegistered, let principal = user.principal,
                  principal.issuer == owner.issuer, principal != owner else { return nil }
            let pair = AccountCallPair(owner, principal)
            guard let call = calls[pair.id], call.accountPair == pair else { return nil }
            let fingerprint = try restoreRecipientFingerprint(for: user, in: call, principal: principal)
            return .init(id: user.id, principal: principal, restoreRecipientFingerprint: fingerprint)
        }
        let backupGroups = owned.filter { $0.kind != .direct }.map {
            CallRelationshipBackup.Group(id: $0.id, name: $0.name)
        }
        return try CallRelationshipBackup(owner: owner, groups: backupGroups, contacts: contacts).validated(for: owner)
    }

    func restoreRecipientFingerprint(for user: SavedUser, in call: Record, principal: AccountPrincipal) throws
        -> String? {
        guard user.memberIDs.count == 1, let memberID = user.memberIDs.first,
              let key = user.deviceKeys?[memberID],
              call.kind == .direct, call.accountDevices[memberID] == .init(principal: principal, publicKey: key),
              call.accountDevices.values.filter({ $0.principal == principal }).count == 1,
              !call.excludesMember(memberID, principal: principal)
        else { return nil }
        return try CallRelationshipRestoreRequest.recipientFingerprint(callID: call.id, memberID: memberID, key: key)
    }
}

extension GroupRepository {
    func callRelationshipBackup(as signer: DeviceIdentitySigner, now: TimeInterval) throws -> CallRelationshipBackup {
        guard let current = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now)
        guard localMemberID == signer.memberID else { throw GroupStorageError.identityConflict }
        return try withCurrentSnapshot(current) {
            try current.backupCandidate(memberID: signer.memberID, binding: .init(
                principal: owner, publicKey: signer.publicKey))
        }
    }

    func recordBackupRemoval(_ id: UUID, kind: CallRelationshipBackupRemovals.Kind,
                             afterRemovingFrom next: inout GroupSnapshot) {
        guard let previous = writableSnapshot, let memberID = localMemberID else { return }
        let bindings = previous.groups.compactMap { $0.accountDevices[memberID] }
        guard let binding = bindings.first, bindings.allSatisfy({ $0 == binding }),
              let before = try? previous.backupCandidate(memberID: memberID, binding: binding),
              let after = try? next.backupCandidate(memberID: memberID, binding: binding),
              let removals = try? CallRelationshipBackupRemovals(
                  removing: id, kind: kind, from: before, to: after, continuing: previous.backupRemovals)
        else { return }
        next.backupRemovals = removals
    }
}

/// Local evidence that consecutive explicit removals produced the current candidate.
struct CallRelationshipBackupRemovals: Codable, Equatable {
    enum Kind: String, Codable { case group, contact }
    private struct Item: Codable, Equatable, Hashable {
        let id: UUID
        let kind: Kind
    }
    private struct Step: Codable, Equatable {
        let item: Item
        let before: String
    }
    private let steps: [Step]
    private let result: String

    var isValid: Bool {
        let fingerprints = steps.map(\.before) + [result]
        return !steps.isEmpty && Set(steps.map(\.item)).count == steps.count
            && Set(fingerprints).count == fingerprints.count
            && fingerprints.allSatisfy {
                $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
    }

    fileprivate init?(
        removing id: UUID, kind: Kind, from before: CallRelationshipBackup, to after: CallRelationshipBackup,
        continuing previous: Self?
    ) throws {
        let expected = CallRelationshipBackup(owner: before.owner,
            groups: before.groups.filter { kind != .group || $0.id != id },
            contacts: before.contacts.filter { kind != .contact || $0.id != id })
        guard before != expected, expected == after else { return nil }
        let fingerprint = try CallRelationshipBackupCheckpointStore.fingerprint(before)
        let priorSteps = previous.flatMap { $0.result == fingerprint ? $0.steps : nil } ?? []
        steps = priorSteps + [Step(item: .init(id: id, kind: kind), before: fingerprint)]
        result = try CallRelationshipBackupCheckpointStore.fingerprint(after)
    }

    func permitsClearing(_ backup: CallRelationshipBackup, to empty: CallRelationshipBackup) throws -> Bool {
        guard empty.isEmpty, empty.owner == backup.owner,
              try result == CallRelationshipBackupCheckpointStore.fingerprint(empty) else { return false }
        let fingerprint = try CallRelationshipBackupCheckpointStore.fingerprint(backup)
        guard let start = steps.firstIndex(where: { $0.before == fingerprint }) else { return false }
        let remaining = steps[start...].map(\.item)
        let groups = backup.groups.map { Item(id: $0.id, kind: .group) }
        let contacts = backup.contacts.map { Item(id: $0.id, kind: .contact) }
        return Set(remaining) == Set(groups + contacts)
    }

    func isPresent(in snapshot: GroupSnapshot) -> Bool {
        steps.contains { step in
            switch step.item.kind {
            case .group: snapshot.groups.contains { $0.id == step.item.id }
            case .contact: snapshot.users.contains { $0.id == step.item.id }
            }
        }
    }
}
