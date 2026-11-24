import Foundation
import Logging

extension IntercomViewModel {
    func acceptInviteURL(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) throws {
        groupErrorMessage = nil
        inviteStatusMessage = nil
        let accepted: IntercomGroup?
        do {
            accepted = try applyInviteURL(url, now: now)
        } catch {
            let rejection = InviteRejection(error)
            AppLoggers.app.warning("app.deeplink.invite.rejected", metadata: InviteDeepLinkLog.rejected(rejection))
            // Storage and account failures already carry their own recovery action.
            if groupErrorMessage == nil { groupErrorMessage = rejection.notice }
            throw error
        }
        if let accepted {
            if accepted.kind == .group {
                resumeOrdinaryGroupReply(for: accepted)
                requestInvitationInternetReply(restart: true)
            }
            AppLoggers.app.info(
                "app.deeplink.invite.accepted",
                metadata: InviteDeepLinkLog.accepted(groupID: accepted.id, kind: accepted.kind))
        } else {
            AppLoggers.app.warning(
                "app.deeplink.invite.rejected",
                metadata: InviteDeepLinkLog.rejected(.conflictingDirectInvitation))
        }
    }

    /// Returns the joined group, or nil when a crossed direct invitation keeps the existing call.
    private func applyInviteURL(_ url: URL, now: TimeInterval) throws -> IntercomGroup? {
        guard canStartCalls else {
            groupErrorMessage = groupStorageNotice
            throw IntercomGroupError.storageUnavailable
        }
        let token = try decodeInviteForLocalRecipient(url, now: now)
        let kind: IntercomGroup.Kind = token.recipientMemberID == nil && token.accountPair == nil ? .group : .direct
        let existing = groups.first { $0.id == token.groupID }
        if let existing, existing.kind != kind || existing.accountPair != token.accountPair {
            throw GroupInviteTokenError.incompatibleCall
        }

        let accepted = try token.accept(
            signer: internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
            displayName: localMemberIdentity.displayName, trust: try internetSettingsStore.identityTrust(),
            now: now)
        guard kind != .group || !groupRepository.hasRetiredGroupLink(accepted) else {
            throw GroupInviteTokenError.retiredGroupLink
        }
        let previous: GroupAccessCredential?
        do { previous = try groupRepository.credential(for: token.groupID) } catch {
            reportGroupStorageError(error); throw error
        }
        // Account calls converge by principal, independently of which device invited.
        // Do not replace a call that has already connected; reconnect explicitly.
        let keepsLocalKey = token.accountPair.map { $0.first == localAccountPrincipal }
            ?? (localMemberIdentity.memberID < token.inviterMemberID)
        let changesKey = previous?.secret != token.groupSecret
        if kind == .direct, previous != nil, changesKey, let existing, keepsLocalKey {
            selectGroup(existing)
            groupCallIssue = .crossedDirectInvitation(groupID: existing.id)
            return nil
        }
        guard !changesKey || activeGroupID != token.groupID else {
            throw GroupInviteTokenError.activeGroupKeyChanged
        }
        let inviterName = groupRepository.inviterName(for: token)
        if let existing, !changesKey || token.accountPair != nil {
            return try updateGroupFromInvite(existing, accepted: accepted, inviterName: inviterName,
                                             replacementKey: changesKey ? token.groupSecret : nil, now: now)
        }
        return try saveGroupFromInvite(
            token, kind: kind, accepted: accepted, inviterName: inviterName, now: now)
    }

    private func decodeInviteForLocalRecipient(_ url: URL, now: TimeInterval) throws -> GroupInviteToken {
        let token: GroupInviteToken
        do { token = try GroupInviteTokenCodec.decodeJoinURL(url) } catch let error as GroupInviteTokenError {
            throw error
        } catch { throw GroupInviteTokenError.invalidTokenEncoding }
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }
        guard token.isAddressed(to: localMemberIdentity.memberID, principal: localAccountPrincipal) else {
            throw GroupInviteTokenError.wrongRecipient
        }
        return token
    }

    private func updateGroupFromInvite(
        _ existing: IntercomGroup, accepted: AcceptedDirectInvitation, inviterName: String,
        replacementKey: String?, now: TimeInterval
    ) throws -> IntercomGroup {
        do {
            try groupRepository.acceptInvitation(
                accepted, inviterName: inviterName, retainingMemberIDs: Set(currentRepresentativeProfiles.keys),
                replacementAccountCallKey: replacementKey, now: now)
            refreshStoredAccountCall(existing.id)
            refreshGroupStorageStatus()
        } catch { reportGroupStorageError(error); throw error }
        let joined = groups.first { $0.id == existing.id } ?? existing
        if replacementKey != nil, selectedGroup?.id == joined.id { selectedGroup = nil }
        selectGroup(joined)
        inviteStatusMessage = "JOINED \(existing.name)"
        return joined
    }

    private func saveGroupFromInvite(
        _ token: GroupInviteToken, kind: IntercomGroup.Kind, accepted: AcceptedDirectInvitation,
        inviterName: String, now: TimeInterval
    ) throws -> IntercomGroup {
        var members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
        let ownOtherDevice = accepted.inviter.principal != nil && accepted.inviter.principal == localAccountPrincipal
        if token.inviterMemberID != localMemberIdentity.memberID && !ownOtherDevice {
            members.append(GroupMember(id: token.inviterMemberID, displayName: inviterName))
        }
        var devices: [String: AccountDeviceBinding] = [:]
        if token.accountPair != nil || kind == .group {
            if let local = localAccountPrincipal {
                let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
                devices[signer.memberID] = .init(principal: local, publicKey: signer.publicKey)
            }
            if let remote = accepted.inviter.principal, !ownOtherDevice {
                devices[token.inviterMemberID] = .init(principal: remote, publicKey: accepted.inviter.publicKey)
            }
        }
        let group = try IntercomGroup(
            id: token.groupID,
            name: token.groupName,
            members: members,
            kind: kind, accountPair: token.accountPair, accountDevices: devices
        )
        var updated = groups
        if let existingIndex = updated.firstIndex(where: { $0.id == group.id }) {
            updated[existingIndex] = group
        } else {
            updated.insert(group, at: 0)
        }
        do {
            try groupRepository.save(updated, credential: .init(groupID: token.groupID, secret: token.groupSecret),
                                     acceptedInvitation: accepted, inviterName: inviterName, now: now)
            refreshGroupStorageStatus()
        } catch {
            reportGroupStorageError(error)
            throw error
        }
        groups = updated
        if selectedGroup?.id == group.id { selectedGroup = nil }
        selectGroup(group)
        inviteStatusMessage = "JOINED \(token.groupName)"
        return group
    }
}
