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
                      && contact.principal != owner
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
        let peers = Set(owned.compactMap { $0.accountPair?.other(than: owner) })
        let contacts = users.compactMap { user -> CallRelationshipBackup.Contact? in
            guard user.isRegistered, let principal = user.principal,
                  principal.issuer == owner.issuer, peers.contains(principal) else { return nil }
            return .init(id: user.id, principal: principal)
        }
        let backupGroups = owned.filter { $0.kind != .direct }.map {
            CallRelationshipBackup.Group(id: $0.id, name: $0.name)
        }
        return try CallRelationshipBackup(owner: owner, groups: backupGroups, contacts: contacts).validated(for: owner)
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

    func rememberLastBackupRemoval(_ id: UUID, kind: CallRelationshipBackupRemoval.Kind,
                                   afterRemovingFrom next: inout GroupSnapshot) {
        guard let previous = writableSnapshot, let memberID = localMemberID else { return }
        let bindings = previous.groups.compactMap { $0.accountDevices[memberID] }
        guard let binding = bindings.first, bindings.allSatisfy({ $0 == binding }),
              let backup = try? previous.backupCandidate(memberID: memberID, binding: binding),
              let removal = try? CallRelationshipBackupRemoval(last: id, kind: kind, in: backup),
              !removal.isPresent(in: next) else { return }
        next.lastBackupRemoval = removal
    }
}

/// Evidence for replacing one exact, previously saved nonempty candidate with an empty one.
struct CallRelationshipBackupRemoval: Codable, Equatable {
    enum Kind: String, Codable { case group, contact }
    let id: UUID
    let kind: Kind
    let fingerprint: String

    var isValid: Bool {
        fingerprint.utf8.count == 64
            && fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    fileprivate init?(last id: UUID, kind: Kind, in backup: CallRelationshipBackup) throws {
        guard Self.containsOnly(id, kind: kind, in: backup) else { return nil }
        self.id = id
        self.kind = kind
        fingerprint = try CallRelationshipBackupCheckpointStore.fingerprint(backup)
    }

    func permitsClearing(_ backup: CallRelationshipBackup) throws -> Bool {
        guard Self.containsOnly(id, kind: kind, in: backup) else { return false }
        return try CallRelationshipBackupCheckpointStore.fingerprint(backup) == fingerprint
    }

    private static func containsOnly(_ id: UUID, kind: Kind, in backup: CallRelationshipBackup) -> Bool {
        backup.groups.map(\.id) == (kind == .group ? [id] : [])
            && backup.contacts.map(\.id) == (kind == .contact ? [id] : [])
    }

    func isPresent(in snapshot: GroupSnapshot) -> Bool {
        switch kind {
        case .group: snapshot.groups.contains { $0.id == id }
        case .contact: snapshot.users.contains { $0.id == id }
        }
    }
}
