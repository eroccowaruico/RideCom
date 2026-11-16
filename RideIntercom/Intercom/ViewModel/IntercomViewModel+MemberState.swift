import AVFoundation
import Codec
import CryptoKit
import Foundation
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    /// The local rider is the first member of every group.
    func withLocalMember(_ update: (inout GroupMember) -> Void) {
        withActiveGroup { group in
            guard !group.members.isEmpty else { return }
            update(&group.members[0])
        }
    }

    func withMember(_ peerID: String, _ update: (inout GroupMember) -> Void) {
        withActiveGroup { group in
            guard let index = group.members.firstIndex(where: { $0.id == peerID }) else { return }
            update(&group.members[index])
        }
    }

    func setVoiceActive(_ isActive: Bool) {
        isVoiceActive = isActive
        withLocalMember { $0.isTalking = isActive }
    }

    func resetVoiceLevelWindows() {
        localVoicePeakWindow = VoicePeakWindow()
        remoteVoicePeakWindows.removeAll()
    }

    func setLocalVoiceLevel(_ level: Float) {
        let clampedLevel = min(1, max(0, level))
        let peakLevel = localVoicePeakWindow.record(clampedLevel)
        withLocalMember { member in
            member.voiceLevel = clampedLevel
            member.voicePeakLevel = peakLevel
        }
    }

    func setRemotePeer(_ peerID: String, isTalking: Bool, voiceLevel: Float? = nil) {
        var peakLevel: Float?
        if let voiceLevel {
            let clampedLevel = min(1, max(0, voiceLevel))
            peakLevel = remoteVoicePeakWindows[peerID, default: VoicePeakWindow()].record(clampedLevel)
        } else if !isTalking {
            remoteVoicePeakWindows.removeValue(forKey: peerID)
        }

        withMember(peerID) { member in
            member.isTalking = isTalking
            if let voiceLevel {
                member.voiceLevel = min(1, max(0, voiceLevel))
                member.voicePeakLevel = peakLevel ?? 0
            } else if !isTalking {
                member.silence()
            }
        }
    }

    func setRemotePeerMuteState(peerID: String, isMuted: Bool) {
        withMember(peerID) { member in
            member.isMuted = isMuted
            if isMuted { member.silence() }
        }
    }

    func setLocalActiveCodec(_ codec: AudioCodecIdentifier) {
        withLocalMember { $0.activeCodec = codec }
    }

    func setRemotePeerCodec(_ peerID: String, codec: AudioCodecIdentifier) {
        withMember(peerID) { $0.activeCodec = codec }
    }

    func markPlayedAudioFrame(peerID: String) {
        withMember(peerID) { member in
            member.playedAudioFrameCount += 1
            member.queuedAudioFrameCount = max(0, member.queuedAudioFrameCount - 1)
        }
    }

    func markConnectedMembers(peerIDs: [String]) {
        let connectedPeerIDSet = Set(peerIDs)
        let authenticatedPeerIDSet = Set(authenticatedPeerIDs)
        withActiveGroup { group in
            for index in group.members.indices {
                let id = group.members[index].id
                if id == localMemberIdentity.memberID {
                    group.members[index].connectionState = isAudioReady ? .connected : .offline
                    group.members[index].authenticationState = .open
                } else if connectedPeerIDSet.contains(id) {
                    group.members[index].connectionState = .connected
                    group.members[index].authenticationState = authenticatedPeerIDSet.contains(id) ? .authenticated : .pending
                } else {
                    group.members[index].leaveCall()
                }
            }
        }
    }

    func markMembers(_ state: PeerConnectionState) {
        withActiveGroup { group in
            for index in group.members.indices {
                let id = group.members[index].id
                if state == .offline { group.members[index].leaveCall() }
                group.members[index].connectionState = state
                if id == localMemberIdentity.memberID {
                    group.members[index].authenticationState = .open
                } else if state == .connected {
                    group.members[index].authenticationState = authenticatedPeerIDs.contains(id) ? .authenticated : .pending
                } else if state == .connecting {
                    group.members[index].authenticationState = .pending
                }
            }
        }
    }

    func replaceSelectedGroup(_ group: IntercomGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        var updated = groups
        updated[index] = group
        if commitGroups(updated) { selectedGroup = groups[index] }
    }

    func persistGroups() {
        _ = commitGroups(groups)
    }

    @discardableResult
    func commitGroups(_ updated: [IntercomGroup]) -> Bool {
        guard canStartCalls else { groupErrorMessage = groupStorageNotice; return false }
        do {
            try groupRepository.save(updated)
            groups = updated
            refreshGroupStorageStatus()
            return true
        } catch {
            reportGroupStorageError(error)
            return false
        }
    }

    func isPendingInviteMemberID(_ memberID: String) -> Bool {
        memberID.hasPrefix(Self.pendingInviteMemberPrefix)
    }

    func credential(for group: IntercomGroup) throws -> GroupAccessCredential? {
        guard canStartCalls else { throw IntercomGroupError.storageUnavailable }
        let secret = try groupRepository.credential(for: group.id)?.secret ?? group.accessSecret
        guard let secret, !secret.isEmpty else { return nil }
        return GroupAccessCredential(groupID: group.id, secret: secret)
    }
}
