import Foundation

/// Durable identity only. Runtime state and secrets never enter this format.
struct GroupSnapshot: Codable, Equatable {
    static let currentVersion = 17
    struct GroupRemovalReceipt: Codable, Equatable {
        let groupID: UUID
        let eventID: UUID
        let signedDigest: Data
        let expiresAt: TimeInterval

        var isValid: Bool { signedDigest.count == 32 && expiresAt.isFinite && expiresAt >= 0 }
    }
    struct GroupLinkReceipt: Codable, Equatable {
        let groupID: UUID
        let receiptID: UUID
        /// Old acknowledged receipts only recorded their IDs.
        let expiresAt: TimeInterval?
        var retired: Bool
    }
    struct RemovedMember: Codable, Equatable {
        var memberIDs: Set<String>
        let principal: AccountPrincipal?
        let removedAt: TimeInterval
        /// Nil for removals from before the invitation IDs were recorded.
        var priorInvitationIDs: Set<UUID>?
        var reinstated: Bool?

        var isExcluded: Bool { reinstated != true }

        func blocksInvitation(_ id: UUID, issuedAt: TimeInterval) -> Bool {
            priorInvitationIDs?.contains(id) ?? (issuedAt <= removedAt)
        }

        func matches(_ memberID: String, principal: AccountPrincipal?) -> Bool {
            memberIDs.contains(memberID) || (principal != nil && self.principal == principal)
        }

        var isValid: Bool {
            !memberIDs.isEmpty && memberIDs.allSatisfy {
                IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix)
            } && (principal?.isValid ?? true) && removedAt.isFinite && removedAt >= 0
        }
    }
    struct Member: Codable, Equatable {
        var id: String
        var displayName: String
        var userID: UUID?
        var localName: String?
    }
    struct Record: Codable, Equatable {
        var id: UUID
        var name: String
        var members: [Member]
        var credentialReference: UUID?
        var kind: IntercomGroup.Kind?
        var accountPair: AccountCallPair?
        var accountDevices: [String: AccountDeviceBinding] = [:]
        var invitationDeviceKeys: [String: String]?
        var pendingInvitation: DirectInvitationReceipt?
        var receivedInvitationIDs: [UUID] = []
        var lastSponsoredStart: TimeInterval?
        /// True when this device joined the group through someone's invitation, so someone else owns it.
        /// Nil (groups made here, and groups saved before this was kept) means you own it.
        var joinedByInvitation: Bool?
        /// Only newly received groups have false; nil preserves the behavior of legacy records.
        var groupTabOfferAcknowledged: Bool?
        var removedMembers: [RemovedMember]?

        init(_ group: IntercomGroup, credentialReference: UUID? = nil) {
            id = group.id; name = group.name
            members = group.members.map { Member(id: $0.id, displayName: $0.displayName, localName: $0.localName) }
            self.credentialReference = credentialReference
            kind = group.kind
            accountPair = group.accountPair; accountDevices = group.accountDevices
        }

        private enum CodingKeys: String, CodingKey {
            case id, name, members, credentialReference, kind, pendingInvitation, receivedInvitationIDs, accountPair, accountDevices, invitationDeviceKeys, lastSponsoredStart, joinedByInvitation, groupTabOfferAcknowledged, removedMembers
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            members = try values.decode([Member].self, forKey: .members)
            credentialReference = try values.decodeIfPresent(UUID.self, forKey: .credentialReference)
            kind = try values.decodeIfPresent(IntercomGroup.Kind.self, forKey: .kind)
            accountPair = try values.decodeIfPresent(AccountCallPair.self, forKey: .accountPair)
            accountDevices = try values.decodeIfPresent([String: AccountDeviceBinding].self, forKey: .accountDevices) ?? [:]
            invitationDeviceKeys = try values.decodeIfPresent([String: String].self, forKey: .invitationDeviceKeys)
            pendingInvitation = try values.decodeIfPresent(DirectInvitationReceipt.self, forKey: .pendingInvitation)
            receivedInvitationIDs = try values.decodeIfPresent([UUID].self, forKey: .receivedInvitationIDs) ?? []
            lastSponsoredStart = try values.decodeIfPresent(TimeInterval.self, forKey: .lastSponsoredStart)
            joinedByInvitation = try values.decodeIfPresent(Bool.self, forKey: .joinedByInvitation)
            groupTabOfferAcknowledged = try values.decodeIfPresent(Bool.self, forKey: .groupTabOfferAcknowledged)
            removedMembers = try values.decodeIfPresent([RemovedMember].self, forKey: .removedMembers)
        }
        func group() throws -> IntercomGroup {
            try IntercomGroup(id: id, name: name, members: members.map { GroupMember(id: $0.id, displayName: $0.displayName, localName: $0.localName) }, kind: kind ?? .group, accountPair: accountPair, accountDevices: accountDevices)
        }

        func matchesInvitationDeviceKey(_ key: String, for memberID: String) -> Bool {
            invitationDeviceKeys?[memberID].map { $0 == key } ?? true
        }

        func excludesMember(_ memberID: String, principal: AccountPrincipal?) -> Bool {
            removedMembers?.contains { $0.isExcluded && $0.matches(memberID, principal: principal) } == true
        }

        mutating func rememberInvitationDevice(_ identity: VerifiedDeviceProof) throws {
            let memberID = identity.memberID
            guard kind == .group, members.contains(where: { $0.id == memberID }) else { return }
            guard matchesInvitationDeviceKey(identity.publicKey, for: memberID),
                  accountDevices[memberID].map({ $0.publicKey == identity.publicKey }) ?? true else {
                throw GroupStorageError.identityConflict
            }
            var keys = invitationDeviceKeys ?? [:]
            keys[memberID] = identity.publicKey
            invitationDeviceKeys = keys
        }

        mutating func discardInvitationKeysForDepartedMembers() {
            guard let invitationDeviceKeys else { return }
            let memberIDs = Set(members.map(\.id))
            let remaining = invitationDeviceKeys.filter { memberIDs.contains($0.key) }
            self.invitationDeviceKeys = remaining.isEmpty ? nil : remaining
        }

        mutating func reinstateMembers(matching matches: (RemovedMember) -> Bool) {
            guard let removals = removedMembers else { return }
            removedMembers = removals.map { removal in
                guard matches(removal) else { return removal }
                var reinstated = removal
                reinstated.reinstated = true
                return reinstated
            }
        }

        mutating func discardRemovalHistory(withPendingInvitations pending: Set<UUID>) {
            guard let removals = removedMembers else { return }
            let retained = removals.compactMap { removal -> RemovedMember? in
                var removal = removal
                removal.priorInvitationIDs?.formIntersection(pending)
                return removal.isExcluded || !(removal.priorInvitationIDs ?? pending).isEmpty ? removal : nil
            }
            removedMembers = retained.isEmpty ? nil : retained
        }
    }
    var version = Self.currentVersion
    var generation = UUID()
    var groups: [Record] = []
    var users: [SavedUser] = []
    var contactInvitations: [ContactInvitationRecord] = []
    var groupDeliveries: [GroupDeliveryRecord] = []
    var groupLinkReceipts: [GroupLinkReceipt] = []
    var groupRemovalReceipts: [GroupRemovalReceipt] = []

    init(groups: [Record] = [], users: [SavedUser] = [], contactInvitations: [ContactInvitationRecord] = [],
         groupDeliveries: [GroupDeliveryRecord] = [], groupLinkReceipts: [GroupLinkReceipt] = [],
         groupRemovalReceipts: [GroupRemovalReceipt] = []) {
        self.groups = groups
        self.users = users
        self.contactInvitations = contactInvitations
        self.groupDeliveries = groupDeliveries
        self.groupLinkReceipts = groupLinkReceipts
        self.groupRemovalReceipts = groupRemovalReceipts
        synchronizeUserReferences()
    }

    private enum CodingKeys: String, CodingKey {
        case version, generation, groups, users, contactInvitations, groupDeliveries, groupLinkReceipts, groupRemovalReceipts
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        generation = try values.decode(UUID.self, forKey: .generation)
        groups = try values.decode([Record].self, forKey: .groups)
        // A missing directory is valid only in the old format. Never replace
        // unreadable or missing current-format users with an empty directory.
        users = version == 1 ? [] : try values.decode([SavedUser].self, forKey: .users)
        contactInvitations = version < 9
            ? (try values.decodeIfPresent([ContactInvitationRecord].self, forKey: .contactInvitations) ?? [])
            : try values.decode([ContactInvitationRecord].self, forKey: .contactInvitations)
        groupDeliveries = version < 11 ? [] : try values.decode([GroupDeliveryRecord].self, forKey: .groupDeliveries)
        groupLinkReceipts = version < 16 ? [] : try values.decode([GroupLinkReceipt].self, forKey: .groupLinkReceipts)
        groupRemovalReceipts = version < 17 ? [] : try values.decode([GroupRemovalReceipt].self, forKey: .groupRemovalReceipts)
    }

    func upgraded() -> GroupSnapshot {
        guard version < Self.currentVersion else { return self }
        var records = groups
        if version < 3 { for index in records.indices { records[index].kind = .group } }
        if version < 5 { for index in records.indices { records[index].pendingInvitation = nil } }
        var next = GroupSnapshot(groups: records, users: users, contactInvitations: contactInvitations,
                                 groupDeliveries: groupDeliveries, groupLinkReceipts: groupLinkReceipts)
        if version < 10 {
            for index in next.contactInvitations.indices {
                let record = next.contactInvitations[index]
                if let peer = record.peerMemberID, let user = next.users.first(where: { $0.memberIDs.contains(peer) }) {
                    next.contactInvitations[index].personID = user.id
                } else if record.direction == .outgoing && (record.state == .pending || record.state == .expired) {
                    let user = SavedUser(displayName: record.nickname ?? "Invitation", memberIDs: [], localName: record.nickname)
                    next.users.append(user)
                    next.contactInvitations[index].personID = user.id
                } else if record.direction == .incoming && record.state == .pending {
                    // An old received checkpoint must not retry a relationship removed from the directory.
                    next.contactInvitations[index].state = .cancelled
                    next.contactInvitations[index].credentialReference = nil
                }
            }
        }
        next.synchronizeUserReferences()
        return next
    }

    mutating func synchronizeUserReferences() {
        let people = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in contactInvitations.indices {
            let record = contactInvitations[index]
            if record.direction == .outgoing, record.state == .pending || record.state == .expired,
               let person = record.personID.flatMap({ people[$0] }), !person.isRegistered {
                contactInvitations[index].nickname = person.resolvedDisplayName
            }
        }
        let directory = Dictionary(users.flatMap { user in user.memberIDs.map { ($0, user) } },
                               uniquingKeysWith: { first, _ in first })
        for groupIndex in groups.indices {
            for index in groups[groupIndex].members.indices {
                let member = groups[groupIndex].members[index]
                if let invitation = contactInvitations.first(where: { $0.invitedGroupID == groups[groupIndex].id
                    && $0.direction == .outgoing && $0.state != .cancelled && $0.pendingGroupMemberID == member.id }),
                   let person = invitation.personID.flatMap({ people[$0] }), !person.isRegistered {
                    groups[groupIndex].members[index].displayName = person.resolvedDisplayName
                    groups[groupIndex].members[index].localName = nil
                }
                // Group presence is not a direct invitation. Keep group metadata
                // without copying unrelated riders into the address book.
                let user = directory[member.id] ?? groups[groupIndex].accountDevices[member.id].flatMap { binding in
                    users.first { $0.principal == binding.principal }
                }
                groups[groupIndex].members[index].userID = user?.id
                if let user {
                    groups[groupIndex].members[index].displayName = user.displayName
                    groups[groupIndex].members[index].localName = user.localName
                }
            }
        }
    }

    func hasRetiredGroupLink(_ receipt: DirectInvitationReceipt) -> Bool {
        groupLinkReceipts.contains { $0.retired && $0.groupID == receipt.groupID && $0.receiptID == receipt.id }
    }

    mutating func retireGroupLinks(from removed: Record) {
        let known = Set(groupLinkReceipts.lazy.filter { $0.groupID == removed.id }.map(\.receiptID))
        for index in groupLinkReceipts.indices where groupLinkReceipts[index].groupID == removed.id {
            groupLinkReceipts[index].retired = true
        }
        for receiptID in removed.receivedInvitationIDs where !known.contains(receiptID) {
            let expiry = removed.pendingInvitation.flatMap { $0.id == receiptID ? $0.invitation?.expiresAt : nil }
            groupLinkReceipts.append(.init(groupID: removed.id, receiptID: receiptID, expiresAt: expiry, retired: true))
        }
    }

    mutating func discardExpiredRetiredGroupLinks(now: TimeInterval) {
        groupLinkReceipts.removeAll { $0.retired && ($0.expiresAt.map { $0 <= now } ?? false) }
    }

    func validated() throws -> GroupSnapshot {
        guard (1...Self.currentVersion).contains(version) else { throw GroupStorageError.unsupportedVersion }
        guard version < 3 || groups.allSatisfy({ $0.kind != nil }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 3 || groups.allSatisfy({ $0.kind == nil || $0.kind == .group }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 6 || groups.allSatisfy({ $0.accountPair == nil && $0.accountDevices.isEmpty }) else { throw IntercomGroupError.invalidStoredGroups }
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 9 || contactInvitations.isEmpty else { throw IntercomGroupError.invalidStoredGroups }
        guard contactInvitations.count <= 1024, contactInvitations.allSatisfy(\.isValid),
              Set(contactInvitations.map(\.id)).count == contactInvitations.count else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 11 || groupDeliveries.isEmpty, groupDeliveries.count <= 512,
              groupDeliveries.allSatisfy(\.isValid), Set(groupDeliveries.map(\.id)).count == groupDeliveries.count else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 12 || groupDeliveries.allSatisfy({ $0.direction == .outgoing || $0.state == .received })
        else { throw IntercomGroupError.invalidStoredGroups }
        let regularGroupIDs = Set(groups.filter { $0.kind == .group }.map(\.id))
        guard version >= 17 || groupRemovalReceipts.isEmpty,
              groupRemovalReceipts.count <= 1024, groupRemovalReceipts.allSatisfy(\.isValid),
              Set(groupRemovalReceipts.map { [$0.groupID, $0.eventID] }).count == groupRemovalReceipts.count
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 16 || groupLinkReceipts.isEmpty,
              Set(groupLinkReceipts.map { [$0.groupID, $0.receiptID] }).count == groupLinkReceipts.count,
              groupLinkReceipts.allSatisfy({ record in
                  (record.expiresAt.map { $0.isFinite && $0 >= 0 } ?? record.retired)
                      && (record.retired || regularGroupIDs.contains(record.groupID))
              }) else { throw IntercomGroupError.invalidStoredGroups }
        let references = groups.compactMap(\.credentialReference) + contactInvitations.compactMap(\.credentialReference) + groupDeliveries.compactMap(\.credentialReference)
        guard Set(references).count == references.count else { throw IntercomGroupError.invalidStoredGroups }
        for record in groups {
            _ = try record.group()
            if let keys = record.invitationDeviceKeys {
                let memberIDs = Set(record.members.map(\.id))
                guard version >= 14, record.kind == .group, !keys.isEmpty, keys.allSatisfy({ memberID, key in
                    memberIDs.contains(memberID) && !memberID.hasPrefix(GroupMember.pendingInvitePrefix)
                        && DeviceIdentityProof.isValidPublicKey(key)
                        && (record.accountDevices[memberID].map { $0.publicKey == key } ?? true)
                }) else { throw IntercomGroupError.invalidStoredGroups }
            }
            if let removed = record.removedMembers, !removed.isEmpty {
                guard version >= 13, record.kind == .group, removed.allSatisfy({
                    $0.isValid && (version >= 15 || ($0.priorInvitationIDs == nil && $0.reinstated == nil))
                }),
                      !record.members.contains(where: { member in
                          record.excludesMember(member.id, principal: record.accountDevices[member.id]?.principal)
                      }) else { throw IntercomGroupError.invalidStoredGroups }
            }
            if let start = record.lastSponsoredStart {
                guard start.isFinite, start > 0 else { throw IntercomGroupError.invalidStoredGroups }
            }
        }
        for record in groups {
            guard Set(record.receivedInvitationIDs).count == record.receivedInvitationIDs.count,
                  record.receivedInvitationIDs.count <= 1024 else { throw IntercomGroupError.invalidStoredGroups }
            if let receipt = record.pendingInvitation {
                guard (version < 5 || receipt.isValid), receipt.kind == .accepted, receipt.groupID == record.id else { throw IntercomGroupError.invalidStoredGroups }
                if version >= 5 {
                    guard receipt.invitation != nil, receipt.proof != nil, let acceptance = receipt.acceptanceProof,
                          receipt.acknowledgementProof == nil,
                          (try? acceptance.verify(receipt.identityMessage(), purpose: .acceptInvitation, memberID: receipt.inviteeMemberID)) != nil else {
                        throw IntercomGroupError.invalidStoredGroups
                    }
                }
            }
        }
        if version >= 2 {
            let principals = users.compactMap(\.principal)
            guard Set(principals).count == principals.count, principals.allSatisfy(\.isValid), users.allSatisfy({ user in
                guard let keys = user.deviceKeys else { return user.principal == nil }
                return Set(keys.keys) == Set(user.memberIDs) && keys.values.allSatisfy(DeviceIdentityProof.isValidPublicKey)
            }) else { throw IntercomGroupError.invalidStoredGroups }
            guard users.filter({ !$0.isRegistered }).allSatisfy({ $0.principal == nil && $0.deviceKeys == nil }) else {
                throw IntercomGroupError.invalidStoredGroups
            }
            guard users.allSatisfy({ $0.usesProvisionalName != true || $0.localName != nil }) else {
                throw IntercomGroupError.invalidStoredGroups
            }
            let memberIDs = users.flatMap(\.memberIDs)
            guard Set(users.map(\.id)).count == users.count,
                  Set(memberIDs).count == memberIDs.count,
                  users.allSatisfy({ IntercomGroup.isValidName($0.displayName) && ($0.localName.map(IntercomGroup.isValidName) ?? true) && (version >= 10 || !$0.memberIDs.isEmpty) }),
                  memberIDs.allSatisfy({ IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix) })
            else { throw IntercomGroupError.invalidStoredGroups }
            let directory = Dictionary(uniqueKeysWithValues: users.flatMap { user in user.memberIDs.map { ($0, user) } })
            guard groups.allSatisfy({ group in group.members.allSatisfy { member in
                if member.id.hasPrefix(GroupMember.pendingInvitePrefix) { return member.userID == nil }
                let user = directory[member.id] ?? group.accountDevices[member.id].flatMap { binding in
                    users.first { $0.principal == binding.principal }
                }
                if member.userID == nil { return user == nil }
                return user?.displayName == member.displayName && user?.id == member.userID && user?.localName == member.localName
            } }) else { throw IntercomGroupError.invalidStoredGroups }
        }
        return self
    }
    func encoded() throws -> Data {
        _ = try validated()
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> GroupSnapshot {
        guard bytes.count <= 1_048_576 else { throw IntercomGroupError.invalidStoredGroups }
        // Inspect the version first, even when a future schema has different fields.
        struct Header: Decodable { let version: Int }
        guard (1...Self.currentVersion).contains(try JSONDecoder().decode(Header.self, from: bytes).version)
        else { throw GroupStorageError.unsupportedVersion }
        do {
            return try JSONDecoder().decode(Self.self, from: bytes).validated()
        } catch is IntercomGroupError {
            // Only a decoded violation means stored data is corrupt. Invalid
            // proposed edits must not offer a reset of the valid old snapshot.
            throw IntercomGroupError.invalidStoredGroups
        }
    }
}

enum GroupStorageError: Error, Equatable {
    case busy, unsupportedVersion, changedByAnotherProcess, verificationFailed, invalidUpdate, identityConflict
}

protocol GroupStoring: AnyObject {
    func read() throws -> GroupSnapshot?
    func commit(_ snapshot: GroupSnapshot) throws
    func lock() throws
    func unlock()
    func archive(legacyData: Data?) throws
}

protocol GroupCredentialStoring: AnyObject {
    func saveSecret(_ secret: String, reference: UUID) throws
    func secret(reference: UUID) throws -> String?
    func delete(reference: UUID) throws
    func references() throws -> Set<UUID>
}
