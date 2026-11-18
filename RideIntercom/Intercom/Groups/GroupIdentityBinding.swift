import Foundation

/// Who may occupy a member slot or a saved user. These rules decide from the group, the
/// verified identity and the connected members alone; `GroupRepository` commits the result.
extension IntercomGroup {
    /// Existing device keys remain usable offline. Only a current, trusted account
    /// certificate may enroll an unseen device in an account-addressed call.
    mutating func bindAccountDevice(_ identity: VerifiedDeviceProof, name: String, localMemberID: String?,
                                    retaining connected: Set<String> = []) -> Bool {
        guard let localMemberID, let local = accountDevices[localMemberID]?.principal,
              let remote = accountPair?.other(than: local) else { return false }
        let memberID = identity.memberID
        if let known = accountDevices[memberID] {
            guard known.principal == remote, known.publicKey == identity.publicKey,
                  identity.principal == nil || identity.principal == remote else { return false }
        } else {
            guard identity.principal == remote else { return false }
        }
        if let index = members.firstIndex(where: { $0.id == memberID }) {
            members[index].displayName = name
        } else {
            if members.count == IntercomGroup.maximumMemberCount {
                guard let index = members.firstIndex(where: { $0.id != localMemberID && !connected.contains($0.id) }) else { return false }
                accountDevices.removeValue(forKey: members.remove(at: index).id)
            }
            members.append(.init(id: memberID, displayName: name))
        }
        accountDevices[memberID] = .init(principal: remote, publicKey: identity.publicKey)
        return true
    }

    /// One durable slot per verified person. A valid current representative is
    /// retained; a new device must answer this connection's challenge after it leaves.
    mutating func bindGroupRepresentative(_ identity: VerifiedDeviceProof, name: String, localMemberID: String?,
                                          retaining connected: Set<String>) -> Bool {
        let memberID = identity.memberID
        if let known = accountDevices[memberID] {
            guard known.publicKey == identity.publicKey,
                  identity.principal == nil || identity.principal == known.principal else { return false }
        }
        if let principal = identity.principal {
            if let old = accountDevices.first(where: { $0.value.principal == principal && $0.key != memberID }) {
                guard old.key != localMemberID, !connected.contains(old.key),
                      members.contains(where: { $0.id == old.key }) else { return false }
                members.removeAll { $0.id == memberID }
                guard let index = members.firstIndex(where: { $0.id == old.key }) else { return false }
                let localName = members[index].localName
                members[index] = .init(id: memberID, displayName: name, localName: localName)
                accountDevices.removeValue(forKey: old.key)
            }
            accountDevices[memberID] = .init(principal: principal, publicKey: identity.publicKey)
        }
        if let index = members.firstIndex(where: { $0.id == memberID }) {
            members[index].displayName = name
        } else {
            // Group authentication alone cannot evict an unrelated saved rider.
            guard connected.contains(memberID) else { return false }
            if let slot = members.firstIndex(where: { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) && !$0.id.hasPrefix(GroupMember.pendingInvitePrefix + "contact-") }) {
                let localName = members[slot].localName
                members[slot] = .init(id: memberID, displayName: name, localName: localName)
            } else {
                guard members.count < IntercomGroup.maximumMemberCount else { return false }
                members.append(.init(id: memberID, displayName: name))
            }
        }
        return true
    }
}

extension GroupSnapshot {
    /// Saves a verified person as one user: by device, by account, or by merging the two
    /// entries when a known device turns out to belong to a known account.
    mutating func remember(_ member: GroupMember, identity: VerifiedDeviceProof) throws {
        guard identity.memberID == member.id else { throw GroupStorageError.identityConflict }
        let memberIndex = users.firstIndex { $0.memberIDs.contains(member.id) }
        let accountIndex = identity.principal.flatMap { principal in users.firstIndex { $0.principal == principal } }
        if let memberIndex {
            let existing = users[memberIndex]
            guard existing.deviceKeys?[member.id] == identity.publicKey,
                  existing.principal == nil || identity.principal == nil || existing.principal == identity.principal else {
                throw GroupStorageError.identityConflict
            }
        }
        if let memberIndex, let accountIndex, memberIndex != accountIndex {
            let first = min(memberIndex, accountIndex), second = max(memberIndex, accountIndex)
            let other = users[second]
            // Preserve local naming choices. Conflicting nicknames require an
            // explicit resolution instead of silently discarding either one.
            guard users[first].localName == nil || other.localName == nil
                || users[first].localName == other.localName else { throw GroupStorageError.identityConflict }
            if users[first].localName == nil {
                users[first].usesProvisionalName = other.usesProvisionalName
            } else if other.localName != nil && other.usesProvisionalName != true {
                users[first].usesProvisionalName = false
            }
            users[first].localName = users[first].localName ?? other.localName
            users[first].memberIDs.append(contentsOf: other.memberIDs)
            users[first].deviceKeys = (users[first].deviceKeys ?? [:]).merging(other.deviceKeys ?? [:]) { old, _ in old }
            users[first].principal = identity.principal
            users[first].displayName = member.displayName
            users.remove(at: second)
        } else if let index = memberIndex ?? accountIndex {
            if !users[index].memberIDs.contains(member.id) { users[index].memberIDs.append(member.id) }
            var keys = users[index].deviceKeys ?? [:]; keys[member.id] = identity.publicKey
            users[index].deviceKeys = keys
            users[index].principal = identity.principal ?? users[index].principal
            users[index].displayName = member.displayName
        } else {
            users.append(SavedUser(displayName: member.displayName, memberIDs: [member.id],
                deviceKeys: [member.id: identity.publicKey], principal: identity.principal))
        }
    }
}
