import CryptoKit
import Foundation

extension IntercomViewModel {
    var regularGroups: [IntercomGroup] { groups.filter { $0.kind == .group } }

    func callTitle(for group: IntercomGroup) -> String {
        guard group.kind == .direct else { return group.name }
        return group.members.first { $0.id != localMemberIdentity.memberID }?.resolvedDisplayName ?? "Call"
    }

    var selectedCallTitle: String { selectedGroup.map(callTitle) ?? "Call" }

    var activeDirectCall: IntercomGroup? {
        groups.first { $0.id == activeGroupID && $0.kind == .direct }
    }

    /// The saved user behind a direct call, for User Settings in the call's menu.
    func savedUserID(forDirectCall group: IntercomGroup) -> UUID? {
        guard group.kind == .direct else { return nil }
        let remote = Set(group.members.map(\.id)).subtracting([localMemberIdentity.memberID])
        return savedRemoteUsers.first { !remote.isDisjoint(with: $0.memberIDs) }?.id
    }

    /// The saved call the Users row would start, without selecting or creating it.
    func existingDirectCall(for userID: UUID) -> IntercomGroup? {
        guard let user = savedRemoteUsers.first(where: { $0.id == userID }),
              let target = directCallTarget(for: user) else { return nil }
        return groups.first { $0.id == target.id && $0.kind == .direct }
    }

    /// True while a call with this destination is live, for the list rows' status.
    func isInCall(with destination: CallDestination) -> Bool {
        hasAnyActiveGroupConnection && isActiveCall(destination)
    }

    @discardableResult
    func selectUser(_ userID: UUID, connectIfIdle: Bool = true, allowSwitchingCall: Bool = true) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let user = savedRemoteUsers.first(where: { $0.id == userID }) else {
            groupErrorMessage = "This saved user is no longer available for an individual call."
            return false
        }
        guard let (id, pair) = directCallTarget(for: user) else {
            groupErrorMessage = "The call could not be started."
            if needsInternetEnrollment, !hasAutomaticInternetEnrollmentProof,
               accountCallEnrollmentRecipient(for: user) != nil {
                groupErrorMessage =
                    "Open RideCom, select the same person, then choose Continue with Apple when it appears."
            }
            return false
        }
        let existing = groups.first(where: { $0.id == id })
        if let existing, existing.kind != .direct {
            groupErrorMessage = "The saved call conflicts with another group. Reload your saved groups."
            return false
        }
        guard requireCallSwitchAllowed(to: id, allowSwitchingCall: allowSwitchingCall) else { return false }
        if let existing {
            selectGroup(existing, connectIfIdle: connectIfIdle)
            return true
        }
        do {
            let group = try storeNewDirectCall(for: user, id: id, pair: pair)
            refreshGroupStorageStatus()
            groups.insert(group, at: 0)
            selectGroup(group, connectIfIdle: connectIfIdle)
            return true
        } catch { reportGroupStorageError(error); return false }
    }

    private func storeNewDirectCall(for user: SavedUser, id: UUID, pair: AccountCallPair?) throws -> IntercomGroup {
        let deviceCall = try groupRepository.singleDeviceCall(for: user)
        let pending = deviceCall == nil ? groupRepository.pendingOrdinaryGroupDeviceCallKeys(
            for: user, localPrincipal: localAccountPrincipal, now: Date().timeIntervalSince1970
        ) : nil
        let preferredPeer = deviceCall?.peerID ?? pending?.peerMemberID
        let orderedIDs = (preferredPeer.map { [$0] } ?? []) + user.memberIDs.filter { $0 != preferredPeer }.sorted()
        let remoteIDs = orderedIDs.prefix(IntercomGroup.maximumMemberCount - 1)
        let members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
            + remoteIDs.map { GroupMember(id: $0, displayName: user.displayName, localName: user.localName) }
        var devices: [String: AccountDeviceBinding] = [:]
        var accountSigner: DeviceIdentitySigner?
        if let pair, let local = localAccountPrincipal, let remote = pair.other(than: local) {
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            accountSigner = signer
            devices[signer.memberID] = .init(principal: local, publicKey: signer.publicKey)
            for id in remoteIDs {
                guard let key = user.deviceKeys?[id] else { throw GroupStorageError.identityConflict }
                devices[id] = .init(principal: remote, publicKey: key)
            }
        }
        let group = try IntercomGroup(id: id, name: "Direct Call", members: members, kind: .direct,
                                     accountPair: pair, accountDevices: devices)
        let savedDeviceSecret = pair == nil ? deviceCall?.secret : nil
        let secret = try savedDeviceSecret ?? initialDirectCallSecret(
            for: group, user: user, accountSigner: accountSigner, savedDevicePeer: deviceCall?.peerID, pending: pending
        )
        try groupRepository.save([group] + groups, credential: .init(groupID: id, secret: secret))
        return group
    }

    private func initialDirectCallSecret(for group: IntercomGroup, user: SavedUser,
                                         accountSigner: DeviceIdentitySigner?, savedDevicePeer: String?,
                                         pending: GroupRepository.OrdinaryGroupDeviceCallKeys?) throws -> String {
        if let accountSigner {
            let pendingPeer = pending.flatMap { keys in
                accountSigner.publicKey == keys.localPublicKey && accountSigner.principal == localAccountPrincipal
                    ? keys.peerMemberID : nil
            }
            let onlyKnownPeer = user.memberIDs.count == 1 ? user.memberIDs.first : nil
            if let peer = savedDevicePeer ?? pendingPeer ?? onlyKnownPeer, let binding = group.accountDevices[peer] {
                return try accountSigner.accountDirectCallSecret(
                    peerMemberID: peer, peerPublicKey: binding.publicKey, callID: group.id
                )
            }
        } else if let pending, localAccountPrincipal == nil,
                  let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID,
                                                                           expectedPublicKey: pending.localPublicKey),
                  signer.principal == nil {
            return try signer.ordinaryGroupDirectCallSecret(
                peerMemberID: pending.peerMemberID, peerPublicKey: pending.peerPublicKey
            )
        }
        return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private func directCallTarget(for user: SavedUser) -> (id: UUID, pair: AccountCallPair?)? {
        if let remote = user.principal {
            guard let local = localAccountPrincipal else { return nil }
            let pair = AccountCallPair(local, remote)
            return (pair.id, pair)
        }
        guard user.memberIDs.count == 1, let remoteID = user.memberIDs.first else { return nil }
        let id = IntercomGroup.directCallID(memberIDs: [localMemberIdentity.memberID, remoteID])
        return (id, nil)
    }

    /// Contact registration commits the pair call. Keep it in the in-memory list so
    /// a later save of that list cannot drop it; a live call keeps its runtime state.
    func adoptStoredContactRegistration(with memberID: String, invitationID: UUID) {
        adoptStoredDeviceCall(with: memberID)
        refreshContactInvitationGroup(invitationID)
        if groupRepository.groupDeliveries.contains(where: {
            $0.direction == .outgoing && $0.state == .pending && $0.recipientMemberID == memberID
        }) {
            requestGroupDeliverySync(.localChange)
        }
    }

    func adoptStoredDeviceCall(with memberID: String) {
        let id = IntercomGroup.directCallID(memberIDs: [localMemberIdentity.memberID, memberID])
        if !groups.contains(where: { $0.id == id }),
           let stored = groupRepository.storedGroup(id), stored.kind == .direct {
            groups.insert(stored, at: 0)
        }
    }

    func refreshContactInvitationGroup(_ invitationID: UUID) {
        let invitation = groupRepository.contactInvitations.first { $0.id == invitationID }
        guard let groupID = invitation?.invitedGroupID,
              let stored = groupRepository.storedGroup(groupID) else { return }
        if groups.contains(where: { $0.id == groupID }) {
            refreshStoredAccountCall(groupID)
        } else {
            groups.insert(stored, at: 0)
        }
    }

    /// Merge durable membership without resetting live mute, audio or connection state.
    func refreshStoredAccountCall(_ groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }),
              var stored = groupRepository.storedGroup(groupID) else { return }
        let runtime = Dictionary(uniqueKeysWithValues: groups[index].members.map { ($0.id, $0) })
        stored.members = stored.members.map { member in
            var result = runtime[member.id] ?? member
            result.displayName = member.displayName; result.localName = member.localName
            return result
        }
        groups[index] = stored
        if selectedGroup?.id == groupID { selectedGroup = stored }
    }

    func directCallAccountRecipient(for group: IntercomGroup) -> AccountPrincipal? {
        guard let local = localAccountPrincipal, let remote = group.accountPair?.other(than: local),
              savedRemoteUsers.contains(where: { $0.principal == remote }) else { return nil }
        return remote
    }

    func directCallRecipient(for group: IntercomGroup) -> String? {
        guard group.kind == .direct, group.accountPair == nil,
              let peer = group.members.first(where: { $0.id != localMemberIdentity.memberID }),
              savedRemoteUsers.contains(where: { $0.memberIDs.contains(peer.id) }) else { return nil }
        return peer.id
    }
}
