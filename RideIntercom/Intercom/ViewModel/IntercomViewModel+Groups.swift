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
            if group.members[index].id == localMemberIdentity.memberID {
                group.members[index].authenticationState = .open
            }
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
        do {
            try groupRepository.delete(
                groupID, remaining: remaining, receipt: receipt, now: callAccessNow().timeIntervalSince1970)
        } catch { reportGroupStorageError(error); return false }
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
            groupErrorMessage =
                groupStorageNotice ?? "An active pass is required to remove a member. Check Access in Settings."
            return false
        }
        return applyGroupMemberRemoval(memberID, from: groupID)
    }

    /// The caller authorizes the removal. Applying it requires writable saved groups,
    /// regardless of the local recipient's pass.
    func applyGroupMemberRemoval(
        _ memberID: String, from groupID: UUID, receipt: GroupSnapshot.GroupRemovalReceipt? = nil
    ) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        if memberID == localMemberIdentity.memberID {
            guard groups.contains(where: { $0.id == groupID && $0.kind == .group }) else { return false }
            return deleteGroup(groupID, receipt: receipt)
        }
        let removed: Set<String>
        do {
            removed = try groupRepository.removeGroupMember(
                memberID, from: groupID, receipt: receipt, now: callAccessNow().timeIntervalSince1970)
        } catch { reportGroupStorageError(error); return false }
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
                do { try audioPipeline.stopReceivePeer(id) } catch {
                    audioErrorMessage = "Could not release the rider's audio. Reconnect to reset audio."
                }
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
        guard remoteMembers.count < IntercomGroup.maximumMemberCount, IntercomGroup.isValidName(name),
            !name.contains("|")
        else {
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
        let members =
            [GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)]
            + remoteMembers
        let newGroup = try? IntercomGroup(
            id: groupID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            members: members, accountDevices: groupAccountDevices(for: members)
        )

        guard let newGroup else {
            groupErrorMessage =
                "Could not create the group because the saved rider identity is invalid."
                + " Saved groups have not been changed."
            return false
        }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        do {
            try groupRepository.save(
                [newGroup] + groups, credential: .init(groupID: groupID, secret: secret),
                deliveries: groupDeliveryRecords(for: userIDs, groupID: groupID))
            refreshGroupStorageStatus()
        } catch {
            reportGroupStorageError(error)
            return false
        }
        groups.insert(newGroup, at: 0)
        selectGroup(newGroup)
        requestGroupDeliverySync(.localChange)
        return true
    }
}
