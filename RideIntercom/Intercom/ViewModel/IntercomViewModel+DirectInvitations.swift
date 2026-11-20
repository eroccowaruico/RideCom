import Foundation
import RTC

extension IntercomViewModel {
    // Presentation must not load keys or issue an invitation.
    var canShareSelectedGroup: Bool {
        guard let group = selectedGroup, groups.contains(where: { $0.id == group.id }) else { return false }
        return canShare(group)
    }

    var crossedDirectCallToShare: IntercomGroup? {
        guard case .crossedDirectInvitation(let groupID) = groupCallIssue,
              let group = selectedGroup, group.id == groupID, group.kind == .direct,
              canShareSelectedGroup else { return nil }
        return group
    }

    /// Group Settings shares a saved group by ID, independent of the call being shown.
    func canShareGroup(_ groupID: UUID) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return canShare(group)
    }

    private func canShare(_ group: IntercomGroup) -> Bool {
        guard canEditSavedGroups,
              group.members.contains(where: { $0.id == localMemberIdentity.memberID }),
              !groupsMissingKeys.contains(group.id) || group.accessSecret != nil else { return false }
        guard group.kind == .direct || canManageRegularGroups else { return false }
        return group.kind != .direct || directCallRecipient(for: group) != nil || directCallAccountRecipient(for: group) != nil
    }

    func makeGroupInviteURL(for groupID: UUID) -> URL? {
        guard canShareGroup(groupID), let group = groups.first(where: { $0.id == groupID }) else { return nil }
        return makeInviteURL(for: group)
    }

    func makeSelectedGroupInviteURL(expectedGroupID: UUID? = nil) -> URL? {
        guard canShareSelectedGroup, let group = selectedGroup,
              expectedGroupID == nil || expectedGroupID == group.id else { return nil }
        return makeInviteURL(for: group)
    }

    private func makeInviteURL(for group: IntercomGroup) -> URL? {
        do {
            guard let credential = try credential(for: group) else {
                groupErrorMessage = "This group has no saved key. Ask a member for a new invitation."
                return nil
            }
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let token = try GroupInviteToken.make(authority: invitationAuthority, signer: signer,
                groupID: group.id, groupName: group.name, groupSecret: credential.secret,
                inviterMemberID: localMemberIdentity.memberID, inviterDisplayName: localMemberIdentity.displayName,
                recipientMemberID: directCallRecipient(for: group), recipientAccount: directCallAccountRecipient(for: group))
            return try GroupInviteTokenCodec.joinURL(for: token)
        } catch GroupInviteTokenError.accountVerificationRequired {
            groupErrorMessage = "Verify your account in Internet Connection before sharing a new individual call invitation."
            return nil
        } catch { reportGroupStorageError(error); return nil }
    }

    func sendPendingInvitationReceipt() {
        guard canEditSavedGroups, let groupID = activeGroupID,
              var receipt = groupRepository.pendingInvitation(for: groupID),
              let invitation = receipt.invitation, invitation.expiresAt > Date().timeIntervalSince1970, receipt.proof != nil, receipt.acceptanceProof != nil,
              receipt.inviteeMemberID == localMemberIdentity.memberID, let expectedKey = receipt.inviteeDeviceKey,
              authenticatedPeerIDs.contains(receipt.inviterMemberID) else { return }
        receipt.displayName = localMemberIdentity.displayName
        guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey),
              let proof = try? signer.sign(receipt.identityMessage(), purpose: .acceptInvitation) else { return }
        receipt.acceptanceProof = proof
        sendInvitationReceipt(receipt)
    }

    private func sendInvitationReceipt(_ receipt: DirectInvitationReceipt) {
        guard let payload = try? JSONEncoder().encode(receipt) else { return }
        callSession.sendApplicationData(.init(namespace: DirectInvitationReceipt.namespace, payload: payload))
    }

    func receiveInvitationReceipt(peerID: String, message: ApplicationDataMessage) {
        guard canEditSavedGroups, message.namespace == DirectInvitationReceipt.namespace, message.payload.count <= 8192,
              authenticatedPeerIDs.contains(peerID),
              let receipt = message.decodedPayload(DirectInvitationReceipt.self, from: peerID),
              receipt.isValid, receipt.groupID == activeGroupID else { return }
        do {
            switch receipt.kind {
            case .accepted:
                guard receipt.inviterMemberID == localMemberIdentity.memberID, receipt.inviteeMemberID == peerID else { return }
                guard let verified = try invitationAuthority.verify(receipt, trust: internetSettingsStore.identityTrust()),
                      let expectedKey = receipt.invitation?.inviterDeviceKey else { return }
                let signer = Result { try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID,
                                                                                  expectedPublicKey: expectedKey) }
                try groupRepository.receiveInvitation(verified, signer: try? signer.get())
                adoptStoredDeviceCall(with: peerID)
                refreshGroupStorageStatus()
                sendInvitationReceipt(try receipt.acknowledged(by: signer.get()))
            case .acknowledged:
                guard receipt.inviterMemberID == peerID, receipt.inviteeMemberID == localMemberIdentity.memberID else { return }
                let signer = receipt.inviteeDeviceKey.flatMap {
                    try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: $0)
                }
                try groupRepository.acknowledgeInvitation(receipt, signer: signer)
                adoptStoredDeviceCall(with: peerID)
            }
        } catch { reportGroupStorageError(error) }
    }
}
