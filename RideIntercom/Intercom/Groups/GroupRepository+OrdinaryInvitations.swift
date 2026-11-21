import Foundation

extension GroupRepository {
    /// The inviter's own name wins; the name already saved for them fills in for an invitation that carries none.
    func inviterName(for token: GroupInviteToken) -> String {
        token.inviterDisplayName ?? users.first { $0.memberIDs.contains(token.inviterMemberID) }?.displayName
            ?? "Inviter"
    }

    func hasRetiredGroupLink(_ accepted: AcceptedDirectInvitation) -> Bool {
        snapshot?.hasRetiredGroupLink(accepted.receipt) == true
    }

    func acceptInvitation(
        _ accepted: AcceptedDirectInvitation, inviterName: String, retainingMemberIDs: Set<String> = [],
        replacementAccountCallKey: String? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        guard let snapshot else { throw GroupStorageError.invalidUpdate }
        let credential = replacementAccountCallKey.map {
            GroupAccessCredential(groupID: accepted.receipt.groupID, secret: $0)
        }
        if credential != nil {
            guard snapshot.groups.contains(where: { $0.id == accepted.receipt.groupID && $0.accountPair != nil }) else {
                throw GroupStorageError.invalidUpdate
            }
        }
        try amend(snapshot, credential: credential, now: now) { next in
            try self.storeAcceptedInvitation(
                accepted, inviterName: inviterName, retainingMemberIDs: retainingMemberIDs, in: &next)
        }
    }

    func storeAcceptedInvitation(
        _ accepted: AcceptedDirectInvitation, inviterName: String? = nil, retainingMemberIDs: Set<String> = [],
        in next: inout GroupSnapshot
    ) throws {
        let receipt = accepted.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.invitation != nil, receipt.proof != nil,
              receipt.inviteeMemberID == localMemberID,
              let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }),
              next.groups[index].members.contains(where: { $0.id == receipt.inviteeMemberID }) else {
            throw GroupStorageError.invalidUpdate
        }
        let name =
            inviterName
            ?? next.groups[index].members.first(where: { $0.id == receipt.inviterMemberID })?.displayName
        guard let name, IntercomGroup.isValidName(name) else { throw GroupStorageError.invalidUpdate }
        if next.groups[index].excludesMember(accepted.inviter.memberID, principal: accepted.inviter.principal) {
            throw GroupStorageError.identityConflict
        }
        if next.groups[index].kind == .group, let expiry = receipt.invitation?.expiresAt {
            guard !next.hasRetiredGroupLink(receipt) else { throw GroupInviteTokenError.retiredGroupLink }
            if !next.groupLinkReceipts.contains(where: {
                $0.groupID == receipt.groupID && $0.receiptID == receipt.id
            }) {
                next.groupLinkReceipts.append(
                    .init(groupID: receipt.groupID, receiptID: receipt.id, expiresAt: expiry, retired: false))
            }
        }
        if !next.groups[index].receivedInvitationIDs.contains(receipt.id) {
            try next.remember(.init(id: receipt.inviterMemberID, displayName: name), identity: accepted.inviter)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
        try bindAcceptedInvitationDevice(accepted.inviter, name: name, retaining: retainingMemberIDs,
                                         in: &next.groups[index])
        try next.groups[index].rememberInvitationDevice(accepted.inviter)
        next.groups[index].pendingInvitation = receipt
    }

    private func bindAcceptedInvitationDevice(
        _ inviter: VerifiedDeviceProof, name: String, retaining retainingMemberIDs: Set<String>,
        in record: inout GroupSnapshot.Record
    ) throws {
        guard record.accountPair != nil || record.kind == .group else { return }
        var group = try record.group()
        let localPrincipal = localMemberID.flatMap { group.accountDevices[$0]?.principal }
        if group.kind == .group {
            if inviter.principal == nil || inviter.principal != localPrincipal {
                let retainsActiveRepresentative = group.accountDevices.contains { memberID, binding in
                    memberID != inviter.memberID && binding.principal == inviter.principal
                        && retainingMemberIDs.contains(memberID)
                }
                if !retainsActiveRepresentative {
                    let retained = retainingMemberIDs.union([inviter.memberID])
                    guard
                        group.bindGroupRepresentative(
                            inviter, name: name, localMemberID: localMemberID, retaining: retained)
                    else { throw GroupStorageError.identityConflict }
                }
            }
        } else {
            guard
                group.bindAccountDevice(
                    inviter, name: name, localMemberID: localMemberID,
                    retaining: Set(group.members.map(\.id)))
            else { throw GroupStorageError.identityConflict }
        }
        record.members = GroupSnapshot.Record(group).members
        record.accountDevices = group.accountDevices
    }

    func pendingInvitation(for groupID: UUID) -> DirectInvitationReceipt? {
        snapshot?.groups.first { $0.id == groupID }?.pendingInvitation
    }

    func pendingOrdinaryGroupReplies(now: TimeInterval) -> [DirectInvitationContext] {
        guard let snapshot else { return [] }
        return snapshot.groups.compactMap { group in
            guard let invitation = group.pendingInvitation?.invitation,
                  ordinaryGroupReplyCredentialReference(for: invitation, now: now) != nil else { return nil }
            return invitation
        }
    }

    func rememberIssuedOrdinaryGroupInvitation(_ invitation: DirectInvitationContext, now: TimeInterval) throws {
        guard invitation.isValid, invitation.isOrdinaryGroupInvitation, invitation.inviterMemberID == localMemberID,
              invitation.expiresAt > now, let snapshot,
              let group = snapshot.groups.first(where: { $0.id == invitation.groupID && $0.kind == .group }),
              let reference = group.credentialReference else { throw GroupStorageError.invalidUpdate }
        try amend(snapshot, now: now) { next in
            next.discardIssuedOrdinaryGroupInvitations(now: now)
            guard next.issuedOrdinaryGroupInvitations.count < GroupSnapshot.maximumIssuedOrdinaryGroupInvitations else {
                throw GroupInviteTokenError.activeOrdinaryGroupInvitationLimit
            }
            next.issuedOrdinaryGroupInvitations.append(.init(invitation: invitation, credentialReference: reference))
        }
    }

    func issuedOrdinaryGroupInvitations(now: TimeInterval) -> [DirectInvitationContext] {
        guard let localMemberID, let snapshot else { return [] }
        return snapshot.issuedOrdinaryGroupInvitations.compactMap { issued in
            let invitation = issued.invitation
            guard invitation.inviterMemberID == localMemberID,
                  ordinaryGroupReplyCredentialReference(for: invitation, now: now) != nil else { return nil }
            return invitation
        }
    }

    func ordinaryGroupReplyCredentialReference(for invitation: DirectInvitationContext, now: TimeInterval) -> UUID? {
        guard let localMemberID, let snapshot = writableSnapshot, invitation.isOrdinaryGroupInvitation,
            invitation.expiresAt > now,
              !missingCredentialGroupIDs.contains(invitation.groupID),
            let group = snapshot.groups.first(where: { $0.id == invitation.groupID && $0.kind == .group })
        else { return nil }
        if invitation.inviterMemberID == localMemberID {
            guard snapshot.issuedOrdinaryGroupInvitations.contains(where: {
                $0.invitation == invitation && $0.credentialReference == group.credentialReference
            }) else { return nil }
        } else {
            guard let pending = group.pendingInvitation, pending.inviteeMemberID == localMemberID,
                  pending.invitation == invitation else { return nil }
        }
        return group.credentialReference
    }

    struct OrdinaryGroupReplyCredential: Equatable {
        let reference: UUID
        let credential: GroupAccessCredential
    }

    func ordinaryGroupReplyCredential(for invitation: DirectInvitationContext, now: TimeInterval)
        -> OrdinaryGroupReplyCredential? {
        guard let reference = ordinaryGroupReplyCredentialReference(for: invitation, now: now),
              let credential = try? credential(for: invitation.groupID) else { return nil }
        return .init(reference: reference, credential: credential)
    }

    func allowsStandaloneOrdinaryReply(for groupID: UUID, from peer: VerifiedDeviceProof) -> Bool {
        guard let record = snapshot?.groups.first(where: { $0.id == groupID && $0.kind == .group }) else {
            return false
        }
        return record.members.contains { $0.id == localMemberID }
            && !record.excludesMember(peer.memberID, principal: peer.principal)
            && record.matchesInvitationDeviceKey(peer.publicKey, for: peer.memberID)
            && (record.accountDevices[peer.memberID].map { $0.publicKey == peer.publicKey } ?? true)
    }

    func pendingOrdinaryGroupReceipt(for user: SavedUser, now: TimeInterval) -> DirectInvitationReceipt? {
        let candidates = pendingOrdinaryGroupReceipts(for: user, localPrincipal: nil, now: now)
        return candidates.count == 1 ? candidates.first : nil
    }

    struct OrdinaryGroupDeviceCallKeys {
        let peerMemberID: String
        let peerPublicKey: String
        let localPublicKey: String
    }

    func pendingOrdinaryGroupDeviceCallKeys(for user: SavedUser, localPrincipal: AccountPrincipal?,
                                            now: TimeInterval) -> OrdinaryGroupDeviceCallKeys? {
        let candidates = pendingOrdinaryGroupReceipts(for: user, localPrincipal: localPrincipal, now: now)
        guard let first = candidates.first, let localKey = first.inviteeDeviceKey,
              let peerKey = first.invitation?.inviterDeviceKey,
              candidates.allSatisfy({
                  $0.inviterMemberID == first.inviterMemberID && $0.invitation?.inviterDeviceKey == peerKey
                      && $0.inviteeDeviceKey == localKey
              }) else { return nil }
        return .init(peerMemberID: first.inviterMemberID, peerPublicKey: peerKey, localPublicKey: localKey)
    }

    private func pendingOrdinaryGroupReceipts(for user: SavedUser, localPrincipal: AccountPrincipal?,
                                              now: TimeInterval) -> [DirectInvitationReceipt] {
        guard let snapshot, let localMemberID else { return [] }
        return snapshot.groups.compactMap { group -> DirectInvitationReceipt? in
            guard group.kind == .group,
                  let pending = group.pendingInvitation, pending.inviteeMemberID == localMemberID,
                  let acceptance = pending.acceptanceProof, acceptance.publicKey == pending.inviteeDeviceKey,
                  let invitation = pending.invitation, invitation.isOrdinaryGroupInvitation,
                  invitation.expiresAt > now else { return nil }
            let inviter = pending.inviterMemberID
            guard user.memberIDs.contains(inviter), let key = user.deviceKeys?[inviter],
                  invitation.inviterDeviceKey == key, group.invitationDeviceKeys?[inviter] == key,
                  !group.excludesMember(inviter, principal: user.principal) else { return nil }
            if let localPrincipal, let remote = user.principal {
                guard localPrincipal != remote, localPrincipal.issuer == remote.issuer,
                      group.accountDevices[inviter] == .init(principal: remote, publicKey: key),
                    group.accountDevices[localMemberID]
                        == .init(principal: localPrincipal, publicKey: acceptance.publicKey),
                      acceptance.certificate != nil else { return nil }
            } else {
                guard localPrincipal == nil, user.principal == nil, user.memberIDs.count == 1,
                      group.accountDevices[inviter] == nil, acceptance.certificate == nil else { return nil }
            }
            return pending
        }
    }

    func receiveInvitation(_ verified: VerifiedDirectInvitation, signer: DeviceIdentitySigner? = nil) throws {
        let receipt = verified.receipt
        guard receipt.isValid, receipt.kind == .accepted, receipt.inviterMemberID == localMemberID,
            let snapshot, let record = snapshot.groups.first(where: { $0.id == receipt.groupID })
        else { throw GroupStorageError.invalidUpdate }
        // Persist receipt IDs even if the contact is later deleted. Retrying an
        // already accepted invitation must not silently recreate that contact.
        guard !record.receivedInvitationIDs.contains(receipt.id) else { return }
        let peer = verified.identity
        let known = snapshot.users.first { $0.memberIDs.contains(peer.memberID) }
        let canPrepareDeviceCall = known.map {
            $0.principal == peer.principal && (peer.principal != nil || $0.memberIDs == [peer.memberID])
        } ?? true
        try updateAfterInvitationReply(
            snapshot, receipt: receipt, remote: (peer, canPrepareDeviceCall ? receipt.displayName : nil), signer: signer
        ) { next in
            guard let index = next.groups.firstIndex(where: { $0.id == receipt.groupID }) else {
                throw GroupStorageError.invalidUpdate
            }
            try next.remember(
                .init(id: receipt.inviteeMemberID, displayName: receipt.displayName), identity: verified.identity)
            try next.groups[index].rememberInvitationDevice(verified.identity)
            next.groups[index].receivedInvitationIDs.append(receipt.id)
        }
    }

    @discardableResult
    func acknowledgeInvitation(_ receipt: DirectInvitationReceipt, signer: DeviceIdentitySigner? = nil,
                               trust: DeviceIdentityTrust? = nil) throws -> Bool {
        guard receipt.kind == .acknowledged, let snapshot,
              let index = snapshot.groups.firstIndex(where: { $0.id == receipt.groupID }),
              let pending = snapshot.groups[index].pendingInvitation,
              pending.id == receipt.id, pending.inviterMemberID == receipt.inviterMemberID,
              pending.inviteeMemberID == receipt.inviteeMemberID,
              pending.invitation == receipt.invitation, pending.proof == receipt.proof,
              let proof = receipt.acknowledgementProof,
              proof.publicKey == pending.invitation?.inviterDeviceKey else { return false }
        guard let peer = try? proof.verify(receipt.acknowledgementMessage(), purpose: .acknowledgeInvitation,
                                           memberID: receipt.inviterMemberID, trust: trust) else { return false }
        let person = snapshot.users.first {
            $0.principal == peer.principal && $0.deviceKeys?[peer.memberID] == peer.publicKey
                && (peer.principal != nil || $0.memberIDs == [peer.memberID])
        }
        // A retransmission is signed again and may include a newer display name.
        let acceptance = try? receipt.acceptanceProof?.verify(receipt.identityMessage(), purpose: .acceptInvitation,
                                                              memberID: receipt.inviteeMemberID, trust: trust)
        let matchesAcceptance = acceptance != nil && pending.inviteeDeviceKey == receipt.inviteeDeviceKey
            && pending.inviteeDeviceKey == acceptance?.publicKey
            && (peer.principal == nil ? proof.certificate == nil : acceptance?.principal == signer?.principal)
        try updateAfterInvitationReply(
            snapshot, receipt: receipt, remote: (peer, matchesAcceptance ? person?.displayName : nil), signer: signer
        ) { next in
            next.groups[index].pendingInvitation = nil
        }
        return true
    }

    private func updateAfterInvitationReply(
        _ snapshot: GroupSnapshot, receipt: DirectInvitationReceipt, remote: (peer: VerifiedDeviceProof, name: String?),
        signer: DeviceIdentitySigner?, modify: (inout GroupSnapshot) throws -> Void
    ) throws {
        let peer = remote.peer
        var groups = try snapshot.groups.map { try $0.group() }
        var credential: GroupAccessCredential?
        if let signer, let name = remote.name, signer.memberID == localMemberID,
           peer.memberID != signer.memberID, peer.publicKey != signer.publicKey,
           let invitation = receipt.invitation, invitation.expiresAt > Date().timeIntervalSince1970,
           invitation.isOrdinaryGroupInvitation,
           signer.publicKey == (receipt.kind == .accepted ? invitation.inviterDeviceKey : receipt.inviteeDeviceKey),
           let source = groups.first(where: { $0.id == receipt.groupID && $0.kind == .group }),
           let local = source.members.first(where: { $0.id == signer.memberID }) {
            let id = IntercomGroup.directCallID(memberIDs: [signer.memberID, peer.memberID])
            if !groups.contains(where: { $0.id == id }),
                let secret = try ordinaryReplyDirectCallSecret(
                    signer: signer, peer: peer, acceptance: receipt.acceptanceProof) {
                let direct = try IntercomGroup(id: id, name: "Direct Call",
                    members: [local, .init(id: peer.memberID, displayName: name)], kind: .direct)
                groups.append(direct)
                credential = .init(groupID: id, secret: secret)
            }
        }
        try update(groups, credential: credential, modify: modify)
    }

    private func ordinaryReplyDirectCallSecret(signer: DeviceIdentitySigner, peer: VerifiedDeviceProof,
                                               acceptance: DeviceIdentityProof?) throws -> String? {
        if let local = signer.principal, let remote = peer.principal, local != remote, local.issuer == remote.issuer {
            // Use the same key the first account call derives when only this peer device is known.
            return try signer.accountDirectCallSecret(peerMemberID: peer.memberID, peerPublicKey: peer.publicKey,
                                                      callID: AccountCallPair(local, remote).id)
        }
        guard signer.principal == nil, peer.principal == nil, acceptance?.certificate == nil else { return nil }
        return try signer.ordinaryGroupDirectCallSecret(peerMemberID: peer.memberID, peerPublicKey: peer.publicKey)
    }
}
