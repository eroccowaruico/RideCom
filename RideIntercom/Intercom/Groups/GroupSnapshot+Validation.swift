import Foundation

extension GroupSnapshot {
    func validated() throws -> GroupSnapshot {
        guard (1...Self.currentVersion).contains(version) else { throw GroupStorageError.unsupportedVersion }
        if let completedDirectRestore, version < 30 || !completedDirectRestore.isValid {
            throw IntercomGroupError.invalidStoredGroups
        }
        if let removal = backupRemovals, version < 27 || !removal.isValid || removal.isPresent(in: self) {
            throw IntercomGroupError.invalidStoredGroups
        }
        guard version >= 29 || directRestoreDevices.isEmpty,
              directRestoreDevices.count <= TrackedDirectRestoreDevice.maximumCount,
              Set(directRestoreDevices.map(\.slot)).count == directRestoreDevices.count,
              directRestoreDevices.allSatisfy(\.isValid)
        else { throw IntercomGroupError.invalidStoredGroups }
        try validateGroupHeadersAndInvitations()
        try validateGroupRemovalsAndNearbyCancellations()
        try validateContactDeletionRecords()
        try validateGroupLinkReceipts()
        try validateGroupRecords()
        try validatePendingInvitationReceipts()
        try validateUserDirectory()
        return self
    }

    private func validateGroupHeadersAndInvitations() throws {
        guard version < 3 || groups.allSatisfy({ $0.kind != nil }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 3 || groups.allSatisfy({ $0.kind == nil || $0.kind == .group }) else {
            throw IntercomGroupError.invalidStoredGroups
        }
        guard version >= 6 || groups.allSatisfy({ $0.accountPair == nil && $0.accountDevices.isEmpty }) else {
            throw IntercomGroupError.invalidStoredGroups
        }
        guard groups.count <= 256, Set(groups.map(\.id)).count == groups.count else {
            throw IntercomGroupError.invalidStoredGroups
        }
        guard version >= 24 || issuedOrdinaryGroupInvitations.isEmpty,
              issuedOrdinaryGroupInvitations.count <= Self.maximumIssuedOrdinaryGroupInvitations,
              Set(issuedOrdinaryGroupInvitations.map(\.invitation.id)).count == issuedOrdinaryGroupInvitations.count,
              issuedOrdinaryGroupInvitations.allSatisfy({
                  $0.invitation.isValid && $0.invitation.isOrdinaryGroupInvitation && containsOrdinaryGroup(for: $0)
              }) else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 9 || contactInvitations.isEmpty else { throw IntercomGroupError.invalidStoredGroups }
        guard contactInvitations.count <= 1024, contactInvitations.allSatisfy(\.isValid),
              Set(contactInvitations.map(\.id)).count == contactInvitations.count
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 11 || groupDeliveries.isEmpty, groupDeliveries.count <= Self.maximumGroupDeliveries,
              groupDeliveries.allSatisfy(\.isValid), Set(groupDeliveries.map(\.id)).count == groupDeliveries.count
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 12 || groupDeliveries.allSatisfy({ $0.direction == .outgoing || $0.state == .received })
        else { throw IntercomGroupError.invalidStoredGroups }
    }

    private func validateGroupRemovalsAndNearbyCancellations() throws {
        guard version >= 17 || groupRemovalReceipts.isEmpty,
              groupRemovalReceipts.count <= 1024, groupRemovalReceipts.allSatisfy(\.isValid),
              Set(groupRemovalReceipts.map { [$0.groupID, $0.eventID] }).count == groupRemovalReceipts.count
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 18 || nearbyGroupCancellations.isEmpty,
              nearbyGroupCancellations.count <= Self.maximumGroupDeliveries,
              nearbyGroupCancellations.allSatisfy(\.isValid),
              Set(nearbyGroupCancellations).count == nearbyGroupCancellations.count
        else { throw IntercomGroupError.invalidStoredGroups }
    }

    private func validateContactDeletionRecords() throws {
        guard version >= 19 || contactDeletions.isEmpty, contactDeletions.allSatisfy(\.isValid),
              Set(contactDeletions.map(\.id)).count == contactDeletions.count
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 20 || contactDeletionReceipts.isEmpty, contactDeletionReceipts.allSatisfy(\.isValid),
              Set(contactDeletionReceipts.map(\.id)).count == contactDeletionReceipts.count
        else { throw IntercomGroupError.invalidStoredGroups }
        let pendingContactDeletionIDs = Set(contactDeletions.map(\.id))
        guard version >= 21 || contactDeletionPublications.isEmpty,
              Set(contactDeletionPublications.map(\.id)).count == contactDeletionPublications.count,
              contactDeletionPublications.allSatisfy({
                  $0.isValid && ($0.payload != nil) == pendingContactDeletionIDs.contains($0.id)
              })
        else { throw IntercomGroupError.invalidStoredGroups }
        let contactDeletionReceiptIDs = Set(contactDeletionReceipts.map(\.id))
        guard version >= 22 || contactDeletionRelayReceipts.isEmpty,
              Set(contactDeletionRelayReceipts.map(\.id)).count == contactDeletionRelayReceipts.count,
              contactDeletionRelayReceipts.allSatisfy({ $0.isValid && contactDeletionReceiptIDs.contains($0.id) })
        else { throw IntercomGroupError.invalidStoredGroups }
        guard version >= 23 || contactDeletionFormerPairs.isEmpty, contactDeletionFormerPairs.allSatisfy(\.isValid)
        else { throw IntercomGroupError.invalidStoredGroups }
    }

    private func validateGroupLinkReceipts() throws {
        let regularGroupIDs = Set(groups.filter { $0.kind == .group }.map(\.id))
        guard version >= 16 || groupLinkReceipts.isEmpty,
              Set(groupLinkReceipts.map { [$0.groupID, $0.receiptID] }).count == groupLinkReceipts.count,
              groupLinkReceipts.allSatisfy({ record in
                  (record.expiresAt.map { $0.isFinite && $0 >= 0 } ?? record.retired)
                      && (record.retired || regularGroupIDs.contains(record.groupID))
              }) else { throw IntercomGroupError.invalidStoredGroups }
    }

    private func validateGroupRecords() throws {
        let references = credentialReferences
        guard Set(references).count == references.count else { throw IntercomGroupError.invalidStoredGroups }
        for record in groups {
            _ = try record.group()
            if record.contactRegistration != nil {
                guard version >= 28, record.kind == .direct, record.accountPair == nil else {
                    throw IntercomGroupError.invalidStoredGroups
                }
            }
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
    }

    private func validatePendingInvitationReceipts() throws {
        for record in groups {
            guard Set(record.receivedInvitationIDs).count == record.receivedInvitationIDs.count,
                  record.receivedInvitationIDs.count <= 1024 else { throw IntercomGroupError.invalidStoredGroups }
            if let receipt = record.pendingInvitation {
                guard version < 5 || receipt.isValid, receipt.kind == .accepted, receipt.groupID == record.id
                else { throw IntercomGroupError.invalidStoredGroups }
                if version >= 5 {
                    guard receipt.invitation != nil, receipt.proof != nil, let acceptance = receipt.acceptanceProof,
                          receipt.acknowledgementProof == nil,
                          (try? acceptance.verify(
                              receipt.identityMessage(), purpose: .acceptInvitation,
                              memberID: receipt.inviteeMemberID)) != nil
                    else {
                        throw IntercomGroupError.invalidStoredGroups
                    }
                }
            }
        }
    }

    private func validateUserDirectory() throws {
        guard version >= 2 else { return }
        let principals = users.compactMap(\.principal)
        guard Set(principals).count == principals.count, principals.allSatisfy(\.isValid),
              users.allSatisfy({ user in
                  guard let keys = user.deviceKeys else { return user.principal == nil }
                  return Set(keys.keys) == Set(user.memberIDs)
                      && keys.values.allSatisfy(DeviceIdentityProof.isValidPublicKey)
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
              users.allSatisfy({
                  IntercomGroup.isValidName($0.displayName)
                      && ($0.localName.map(IntercomGroup.isValidName) ?? true)
                      && (version >= 10 || !$0.memberIDs.isEmpty)
              }),
              memberIDs.allSatisfy({
                  IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix)
              })
        else { throw IntercomGroupError.invalidStoredGroups }
        let directory = Dictionary(
            uniqueKeysWithValues: users.flatMap { user in user.memberIDs.map { ($0, user) } })
        guard groups.allSatisfy({ group in
            group.members.allSatisfy { member in
                if member.id.hasPrefix(GroupMember.pendingInvitePrefix) { return member.userID == nil }
                let user = directory[member.id] ?? group.accountDevices[member.id].flatMap { binding in
                    users.first { $0.principal == binding.principal }
                }
                if member.userID == nil { return user == nil }
                return user?.displayName == member.displayName && user?.id == member.userID
                    && user?.localName == member.localName
            }
        }) else { throw IntercomGroupError.invalidStoredGroups }
    }

    mutating func discardIssuedOrdinaryGroupInvitations(now: TimeInterval, replacingKeys: Set<UUID> = []) {
        issuedOrdinaryGroupInvitations = issuedOrdinaryGroupInvitations.filter { issued in
            issued.invitation.expiresAt > now && !replacingKeys.contains(issued.invitation.groupID)
                && containsOrdinaryGroup(for: issued)
        }
    }

    private func containsOrdinaryGroup(for issued: IssuedOrdinaryGroupInvitation) -> Bool {
        groups.contains { group in
            group.id == issued.invitation.groupID && group.kind == .group
                && group.credentialReference == issued.credentialReference
                && group.members.contains { $0.id == issued.invitation.inviterMemberID }
        }
    }
}
