import AVFoundation
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import VADGate

enum GroupCallIssue {
    case notice(String)
    case crossedDirectInvitation(groupID: UUID)

    var message: String {
        switch self {
        case .notice(let message): message
        case .crossedDirectInvitation:
            "You both created a call invitation. Share this call's invitation so you use the same call."
        }
    }
}

extension IntercomViewModel {
    func selectGroup(_ group: IntercomGroup, connectIfIdle: Bool = true) {
        groupErrorMessage = nil
        if selectedGroup?.id == group.id {
            return
        }

        if activeGroupID == group.id {
            if let activeGroup = groups.first(where: { $0.id == group.id }) {
                selectedGroup = activeGroup
            } else {
                selectedGroup = group.withMemberAuthenticationState(.open)
            }
            inviteStatusMessage = nil

            if hasAnyActiveGroupConnection {
                return
            }
        }

        if let activeGroupID,
           activeGroupID != group.id,
           hasAnyActiveGroupConnection {
            selectedGroup = makeInactiveDisplayGroup(from: group)
            inviteStatusMessage = nil
            return
        }

        selectedGroup = group.withMemberAuthenticationState(.open)
        inviteStatusMessage = nil
        if connectIfIdle { connectLocal() }
    }

    func showGroupSelection() {
        groupErrorMessage = nil
        selectedGroup = nil
        inviteStatusMessage = nil
    }


    var hasAnyActiveGroupConnection: Bool {
        guard activeGroupID != nil else { return false }
        return connectionState != .idle || isAudioReady || !authenticatedPeerIDs.isEmpty || localNetworkStatus != .idle
    }

    var presentedConnectionState: CallConnectionState {
        guard selectedGroup?.id == activeGroupID else { return .idle }
        return connectionState
    }

    var presentedLocalNetworkStatus: LocalNetworkStatus {
        guard selectedGroup?.id == activeGroupID else { return .idle }
        return localNetworkStatus
    }

    var hasPresentedAuthenticatedConnection: Bool {
        guard selectedGroup?.id == activeGroupID else { return false }
        return !authenticatedPeerIDs.isEmpty
    }

    /// Everything one connection observed about its peers and audio. A new call and the end of a
    /// call both return it to the same empty state here, so neither can leave a field behind.
    func resetConnectionRuntimeState() {
        callAccessState = CallAccessState()
        lastCallAccessSaveAttempt = nil
        connectionState = .idle
        isVoiceActive = false
        connectedPeerIDs = []
        authenticatedPeerIDs = []
        peerProfiles.removeAll()
        localNetworkStatus = .idle
        lastLocalNetworkPeerID = nil
        lastLocalNetworkEventAt = nil
        remoteVoiceReceivedAt.removeAll()
        remoteRuntimeStatuses.removeAll()
        resetVoiceLevelWindows()
        resetAudioDebugCounters()
    }

    func makeInactiveDisplayGroup(from group: IntercomGroup) -> IntercomGroup {
        var group = group
        for index in group.members.indices {
            group.members[index].leaveCall()
            if group.members[index].id == localMemberIdentity.memberID { group.members[index].authenticationState = .open }
        }
        return group
    }

    func withActiveGroup(_ update: (inout IntercomGroup) -> Void) {
        guard let groupID = activeGroupID ?? selectedGroup?.id,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }

        var group = groups[index]
        update(&group)
        groups[index] = group
        if selectedGroup?.id == group.id {
            selectedGroup = group
        }
    }

    @discardableResult
    func deleteGroup(_ groupID: UUID, receipt: GroupSnapshot.GroupRemovalReceipt? = nil) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        let remaining = groups.filter { $0.id != groupID }
        do { try groupRepository.delete(groupID, remaining: remaining, receipt: receipt, now: callAccessNow().timeIntervalSince1970) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus()
        if activeGroupID == groupID { disconnect() }
        if selectedGroup?.id == groupID { selectedGroup = nil }
        groups = remaining
        discardUnavailableRecentCall()
        requestGroupDeliverySync(.localChange)
        return true
    }

    /// The name stays on this device; renaming does not touch the call.
    @discardableResult
    func renameGroup(_ groupID: UUID, to name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntercomGroup.isValidName(name), !name.contains("|") else {
            groupErrorMessage = "Enter a group name without |."
            return false
        }
        guard let index = groups.firstIndex(where: { $0.id == groupID && $0.kind == .group }) else { return false }
        var updated = groups
        updated[index].name = name
        guard commitGroups(updated) else { return false }
        groupErrorMessage = nil
        if selectedGroup?.id == groupID { selectedGroup?.name = name }
        return true
    }

    @discardableResult
    func removeMember(_ memberID: String, from groupID: UUID) -> Bool {
        guard memberID != localMemberIdentity.memberID,
              let groupIndex = groups.firstIndex(where: { $0.id == groupID && $0.kind == .group }),
              groups[groupIndex].members.contains(where: { $0.id == memberID }) else { return false }
        guard canManageRegularGroups else {
            groupErrorMessage = groupStorageNotice ?? "An active pass is required to remove a member. Check Access in Settings."
            return false
        }
        return applyGroupMemberRemoval(memberID, from: groupID)
    }

    /// The caller authorizes the removal. Applying it requires writable saved groups,
    /// regardless of the local recipient's pass.
    func applyGroupMemberRemoval(_ memberID: String, from groupID: UUID, receipt: GroupSnapshot.GroupRemovalReceipt? = nil) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        if memberID == localMemberIdentity.memberID {
            guard groups.contains(where: { $0.id == groupID && $0.kind == .group }) else { return false }
            return deleteGroup(groupID, receipt: receipt)
        }
        let removed: Set<String>
        do { removed = try groupRepository.removeGroupMember(memberID, from: groupID, receipt: receipt, now: callAccessNow().timeIntervalSince1970) }
        catch { reportGroupStorageError(error); return false }
        refreshStoredAccountCall(groupID)
        refreshGroupStorageStatus()
        groupErrorMessage = nil
        requestGroupDeliverySync(.localChange)
        if activeGroupID == groupID {
            connectedPeerIDs.removeAll { removed.contains($0) }
            authenticatedPeerIDs.removeAll { removed.contains($0) }
            for id in removed { peerProfiles.removeValue(forKey: id) }
            callSession.setAudioPolicy(currentCallAudioPolicy())
            refreshCallAccess()
            for id in removed {
                remoteVoiceReceivedAt.removeValue(forKey: id)
                remoteVoicePeakWindows.removeValue(forKey: id)
                do { try audioPipeline.stopReceivePeer(id) }
                catch { audioErrorMessage = "Could not release the rider's audio. Reconnect to reset audio." }
            }
        }
        return true
    }

    @discardableResult
    func createTalkGroup(name: String = "Talk Group", userIDs: Set<UUID> = [], id: UUID? = nil) -> Bool {
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard requireGroupAccess() else { return false }
        guard let remoteMembers = membersForSavedUsers(userIDs) else { return false }
        guard remoteMembers.count < IntercomGroup.maximumMemberCount, IntercomGroup.isValidName(name), !name.contains("|") else {
            groupErrorMessage = "Enter a group name without | and choose up to 7 other members."
            return false
        }
        let groupID = id ?? UUID()
        if let existing = groups.first(where: { $0.id == groupID }) {
            guard existing.kind == .group, existing.name == name,
                  Set(remoteMembers.map(\.id)).isSubset(of: Set(existing.members.map(\.id))) else { return false }
            selectGroup(existing)
            requestGroupDeliverySync(.localChange)
            return true
        }
        let members = [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)] + remoteMembers
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            members: members, accountDevices: groupAccountDevices(for: members)
        )

        guard let newGroup else {
            groupErrorMessage = "Could not create the group because the saved rider identity is invalid. Saved groups have not been changed."
            return false
        }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        do { try groupRepository.save([newGroup] + groups, credential: .init(groupID: groupID, secret: secret), deliveries: groupDeliveryRecords(for: userIDs, groupID: groupID)); refreshGroupStorageStatus() }
        catch {
            reportGroupStorageError(error)
            return false
        }
        groups.insert(newGroup, at: 0)
        selectGroup(newGroup)
        requestGroupDeliverySync(.localChange)
        return true
    }

    func reserveInviteMemberSlot(displayName: String? = nil) {
        guard requireGroupAccess() else { return }
        guard var group = selectedGroup,
              group.kind == .group,
              group.members.count < IntercomGroup.maximumMemberCount else { return }

        let nextNumber = group.members.count
        let memberID = "\(Self.pendingInviteMemberPrefix)\(group.id.uuidString.prefix(8).lowercased())-\(nextNumber)-\(UUID().uuidString.prefix(8).lowercased())"
        let name = displayName ?? "Invited Rider \(nextNumber)"
        group.members.append(
            GroupMember(
                id: memberID,
                displayName: name,
                authenticationState: .pending,
                connectionState: .connecting
            )
        )
        replaceSelectedGroup(group)
    }

    func acceptInviteURL(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) throws {
        groupErrorMessage = nil
        inviteStatusMessage = nil
        let accepted: IntercomGroup?
        do {
            accepted = try applyInviteURL(url, now: now)
        } catch {
            AppLoggers.app.warning("app.deeplink.invite.rejected", metadata: InviteDeepLinkLog.rejected(error))
            // Storage and account failures already carry their own recovery action.
            if groupErrorMessage == nil { groupErrorMessage = InviteRejection(error).notice }
            throw error
        }
        if let accepted {
            if accepted.kind == .group {
                resumeOrdinaryGroupReply(for: accepted)
                requestOrdinaryGroupInternetReply(restart: true)
            }
            AppLoggers.app.info("app.deeplink.invite.accepted", metadata: InviteDeepLinkLog.accepted(groupID: accepted.id, kind: accepted.kind))
        } else {
            AppLoggers.app.warning("app.deeplink.invite.rejected", metadata: InviteDeepLinkLog.rejected(reason: "conflicting_direct_invitation"))
        }
    }

    /// Returns the joined group, or nil when a crossed direct invitation keeps the existing call.
    private func applyInviteURL(_ url: URL, now: TimeInterval) throws -> IntercomGroup? {
        guard canStartCalls else {
            groupErrorMessage = groupStorageNotice
            throw IntercomGroupError.storageUnavailable
        }
        let token: GroupInviteToken
        do { token = try GroupInviteTokenCodec.decodeJoinURL(url) }
        catch let error as GroupInviteTokenError { throw error }
        catch { throw GroupInviteTokenError.invalidTokenEncoding }
        guard !token.isExpired(now: now) else {
            throw GroupInviteTokenError.expired
        }
        if let recipient = token.recipientMemberID, recipient != localMemberIdentity.memberID {
            groupErrorMessage = "This call invitation is addressed to another rider."
            throw GroupInviteTokenError.wrongRecipient
        }
        if let recipient = token.recipientAccount, recipient != localAccountPrincipal {
            groupErrorMessage = "This call invitation is addressed to another rider."
            throw GroupInviteTokenError.wrongRecipient
        }
        let kind: IntercomGroup.Kind = token.recipientMemberID == nil && token.accountPair == nil ? .group : .direct
        let existing = groups.first { $0.id == token.groupID }
        if let existing, existing.kind != kind || existing.accountPair != token.accountPair {
            groupErrorMessage = "This invitation cannot change an individual call into a group."
            throw GroupInviteTokenError.incompatibleCall
        }

        let accepted = try token.accept(signer: internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
                                        displayName: localMemberIdentity.displayName, trust: try internetSettingsStore.identityTrust(), now: now)
        guard kind != .group || !groupRepository.hasRetiredGroupLink(accepted) else { throw GroupInviteTokenError.retiredGroupLink }
        let previous: GroupAccessCredential?
        do { previous = try groupRepository.credential(for: token.groupID) }
        catch { reportGroupStorageError(error); throw error }
        // Account calls converge by principal, independently of which device invited.
        // Do not replace a call that has already connected; reconnect explicitly.
        let keepsLocalKey = token.accountPair.map { $0.first == localAccountPrincipal }
            ?? (localMemberIdentity.memberID < token.inviterMemberID)
        if kind == .direct, let previous, previous.secret != token.groupSecret, let existing, keepsLocalKey {
            selectGroup(existing)
            groupCallIssue = .crossedDirectInvitation(groupID: existing.id)
            return nil
        }
        let inviterName = groupRepository.inviterName(for: token)
        if let existing, previous?.secret == token.groupSecret {
            do {
                try groupRepository.acceptInvitation(accepted, inviterName: inviterName, retainingMemberIDs: Set(currentRepresentativeProfiles.keys), now: now)
                refreshStoredAccountCall(token.groupID)
                refreshGroupStorageStatus()
            } catch { reportGroupStorageError(error); throw error }
            let joined = groups.first { $0.id == existing.id } ?? existing
            selectGroup(joined)
            inviteStatusMessage = "JOINED \(existing.name)"
            return joined
        }
        guard activeGroupID != token.groupID else {
            groupErrorMessage = "This invitation changes the active group key. Disconnect before opening it again."
            throw GroupInviteTokenError.activeGroupKeyChanged
        }
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
        }
        catch {
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
