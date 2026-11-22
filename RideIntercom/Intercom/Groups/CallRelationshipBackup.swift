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

    fileprivate init(owner: AccountPrincipal, groups: [Group], contacts: [Contact]) {
        version = Self.currentVersion
        self.owner = owner
        self.groups = groups
        self.contacts = contacts
    }

    static func read(_ data: Data, as signer: DeviceIdentitySigner, now: TimeInterval) throws -> Self {
        let owner = try verifiedOwner(of: signer, now: now)
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.owner == owner else { throw GroupStorageError.identityConflict }
        guard backup.version == currentVersion,
              Set(backup.groups.map(\.id)).count == backup.groups.count,
              Set(backup.contacts.map(\.id)).count == backup.contacts.count,
              Set(backup.contacts.map(\.principal)).count == backup.contacts.count,
              backup.groups.allSatisfy({ IntercomGroup.isValidName($0.name) }),
              backup.contacts.allSatisfy({ contact in
                  contact.principal.isValid && contact.principal.issuer == backup.owner.issuer
                      && contact.principal != backup.owner
              }) else { throw GroupStorageError.invalidUpdate }
        return backup
    }

    static func verifiedOwner(
        of signer: DeviceIdentitySigner, now: TimeInterval
    ) throws -> AccountPrincipal {
        guard let identity = signer.identity, identity.expiresAt > now,
              let owner = signer.principal, owner.isValid else { throw GroupStorageError.identityConflict }
        return owner
    }
}

extension GroupRepository {
    func callRelationshipBackup(as signer: DeviceIdentitySigner, now: TimeInterval) throws -> Data {
        guard let current = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now)
        guard localMemberID == signer.memberID else { throw GroupStorageError.identityConflict }

        return try withCurrentSnapshot(current) {
            let binding = AccountDeviceBinding(principal: owner, publicKey: signer.publicKey)
            let owned = current.groups.filter { record in
                record.pendingInvitation == nil && record.accountDevices[signer.memberID] == binding
                    && !record.excludesMember(signer.memberID, principal: owner)
            }
            let peers = Set(owned.compactMap { $0.accountPair?.other(than: owner) })
            let contacts = current.users.compactMap { user -> CallRelationshipBackup.Contact? in
                guard user.isRegistered, let principal = user.principal,
                      principal.issuer == owner.issuer, peers.contains(principal) else { return nil }
                return .init(id: user.id, principal: principal)
            }
            let groups = owned.filter { $0.kind != .direct }.map {
                CallRelationshipBackup.Group(id: $0.id, name: $0.name)
            }
            return try JSONEncoder().encode(CallRelationshipBackup(owner: owner, groups: groups, contacts: contacts))
        }
    }
}
