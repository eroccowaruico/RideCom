import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests.GroupLifecycleTests {
    @Test func viewModelResetAllSettingsKeepsGroupsAndRestoresAudioDefaults() {
        let harness = AppTestSupport.makeHarness()

        harness.viewModel.setAudioSessionProfile(.voiceChat)
        harness.viewModel.setVADSensitivity(.noisy)
        harness.viewModel.setAACELDv2BitRate(128_000)
        harness.viewModel.setOpusBitRate(128_000)
        harness.viewModel.setMasterOutputVolume(2)
        harness.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        harness.viewModel.setReceiveMasterSoundIsolationEnabled(true)
        harness.viewModel.setDuckOthersEnabled(false)
        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        harness.viewModel.setRTCTransportRoute(.webRTC, enabled: false)
        harness.viewModel.toggleOutputMute()
        harness.viewModel.resetAllSettings()

        #expect(harness.viewModel.audioSessionProfile == IntercomViewModel.defaultAudioSessionProfile)
        #expect(harness.viewModel.isDuckOthersEnabled == IntercomViewModel.defaultDuckOthersEnabled)
        #expect(harness.viewModel.vadSensitivity == IntercomViewModel.defaultVADSensitivity)
        #expect(harness.viewModel.preferredTransmitCodec == IntercomViewModel.defaultTransmitCodec)
        #expect(harness.viewModel.aacELDv2BitRate == IntercomViewModel.defaultAACELDv2BitRate)
        #expect(harness.viewModel.opusBitRate == IntercomViewModel.defaultOpusBitRate)
        #expect(harness.viewModel.masterOutputVolume == IntercomViewModel.defaultMasterOutputVolume)
        #expect(harness.viewModel.remoteOutputVolumes.isEmpty)
        #expect(harness.viewModel.remoteSoundIsolationEnabled.isEmpty)
            #expect(
                harness.viewModel.receiveMasterSoundIsolationEnabled
                    == IntercomViewModel.defaultReceiveSoundIsolationEnabled)
        #expect(harness.viewModel.enabledRTCTransportRoutes == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(!harness.viewModel.isOutputMuted)
        #expect(harness.viewModel.groups.count == IntercomSeedData.recentGroups.count)
        #expect(harness.callSession.enabledRouteValues.last == IntercomViewModel.defaultEnabledRTCTransportRoutes)
        #expect(harness.callSession.outputMuteValues.last == false)
    }

    @Test func deletingBrowsedGroupPreservesActiveCallAndRejectsUntrustedMute() async {
        let harness = AppTestSupport.makeHarness()
        let firstGroup = IntercomSeedData.recentGroups[0]
        let secondGroup = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(firstGroup)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.selectGroup(secondGroup)
        harness.viewModel.deleteGroup(secondGroup.id)
        #expect(harness.viewModel.activeGroupID == firstGroup.id)
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.handleTransportEvent(.remotePeerMuteState(peerID: "member-215", isMuted: true))
            #expect(
                harness.viewModel.groups.first { $0.id == firstGroup.id }?.members.first { $0.id == "member-215" }?
                    .isMuted
                    == false)
        harness.viewModel.deleteGroup(firstGroup.id)
        #expect(harness.viewModel.activeGroupID == nil)
        #expect(!harness.viewModel.isAudioReady)
    }

    @Test func deviceLossPausesOwnAudioButPreservesGroupAndDoesNotAutoResume() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let disconnects = harness.callSession.disconnectCallCount
        harness.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: harness.audioSessionBackend.current)))
        #expect(!harness.viewModel.isAudioReady)
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.viewModel.authenticatedPeerIDs == ["member-108"])
            harness.viewModel.handleTransportEvent(
                .authenticated(members: [
                    .init(
                        peer: .init(id: .init(rawValue: "member-108"), displayName: "Rider"), route: .multipeer,
                        isConnected: true, membershipID: UUID())
                ]))
        #expect(!harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func createdGroupUsesSamePersistedRandomKeyForInviteAndConnection() throws {
        let credentials = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: credentials)
        harness.viewModel.createTalkGroup()
        let group = try #require(harness.viewModel.selectedGroup)
        let saved = try #require(try harness.viewModel.groupRepository.credential(for: group.id))
        #expect(Data(base64Encoded: saved.secret)?.count == 32)
        #expect(!saved.secret.contains(group.id.uuidString))
        #expect(harness.callSession.connectedGroup?.accessSecret == saved.secret)
        let url = try #require(harness.viewModel.makeSelectedGroupInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        #expect(token.groupSecret == saved.secret)
        harness.viewModel.disconnect()
        harness.viewModel.connectLocal()
        #expect(harness.callSession.connectedGroup?.accessSecret == token.groupSecret)
        let other = AppTestSupport.makeHarness(groups: [], localMemberID: "other-device")
        try other.viewModel.acceptInviteURL(url)
        #expect(other.callSession.connectedGroup?.accessSecret == saved.secret)
    }

    @Test func missingGroupKeyCannotStartPlaintextCallOrInventInvite() throws {
        let credentials = InMemoryGroupCredentialStore()
        let group = try IntercomGroup(name: "Missing key", members: [.init(id: "local", displayName: "You")])
        let harness = AppTestSupport.makeHarness(groups: [group], credentialStore: credentials)
        harness.viewModel.selectGroup(group)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(harness.viewModel.makeSelectedGroupInviteURL() == nil)
        #expect(harness.viewModel.activeGroupID == nil)
        #expect(harness.viewModel.groupErrorMessage?.contains("key") == true)
    }

    @Test func credentialPersistenceFailureDoesNotCreateOrJoinGroup() throws {
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: RejectingGroupCredentialStore())
        harness.viewModel.createTalkGroup()
        #expect(harness.viewModel.groups.isEmpty)
        #expect(harness.callSession.connectedGroup == nil)
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), credential: .init(groupID: UUID(), secret: "shared"),
                groupName: "Invite", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try harness.viewModel.acceptInviteURL(url) }
        #expect(harness.viewModel.groups.isEmpty)
        #expect(harness.callSession.connectedGroup == nil)
    }

    @Test func emptyInviteCannotReplaceAnExistingGroupKey() throws {
        let credentials = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: credentials)
        harness.viewModel.createTalkGroup()
        let group = try #require(harness.viewModel.selectedGroup)
        let saved = try #require(try harness.viewModel.groupRepository.credential(for: group.id))
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), credential: .init(groupID: group.id, secret: ""),
                groupName: group.name, inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        #expect(throws: (any Error).self) { try harness.viewModel.acceptInviteURL(url) }
        #expect(try harness.viewModel.groupRepository.credential(for: group.id) == saved)
        #expect(harness.callSession.disconnectCallCount == 0)
    }

    @Test func runtimeUpdatesDoNotWriteGroupStorage() throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(harness.viewModel.groups[0])
        let count = harness.groupStore.saveCount
        for _ in 0..<200 {
            harness.viewModel.setLocalVoiceLevel(0.2)
            harness.viewModel.setVoiceActive(true)
            harness.viewModel.setRemotePeer("member-108", isTalking: true, voiceLevel: 0.3)
            harness.viewModel.markPlayedAudioFrame(peerID: "member-108")
        }
        #expect(harness.groupStore.saveCount == count)
        harness.callSession.authenticate(["new-rider"])
        #expect(harness.groupStore.saveCount == count)
        let profile = try testPeerProfile(harness.viewModel, peerID: "new-rider", displayName: "New rider")
            let message = ApplicationDataMessage(
                namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))
        harness.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "new-rider", message: message))
        #expect(harness.groupStore.saveCount == count + 1)
        harness.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "new-rider", message: message))
        #expect(harness.groupStore.saveCount == count + 1)
    }

    @Test func removingMemberFromInactiveGroupPreservesActiveCall() {
        let harness = AppTestSupport.makeHarness()
        let first = harness.viewModel.groups[0]
        harness.viewModel.selectGroup(first)
        harness.viewModel.connectedPeerIDs = ["member-400"]
        harness.viewModel.authenticatedPeerIDs = ["member-400"]
        harness.viewModel.removeMember("member-400", from: harness.viewModel.groups[1].id)
        #expect(harness.viewModel.activeGroupID == first.id)
        #expect(harness.viewModel.connectedPeerIDs == ["member-400"])
        #expect(harness.viewModel.authenticatedPeerIDs == ["member-400"])
    }

    @Test func failedMetadataSaveDoesNotPublishGroupOrLosePreviousKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        harness.groupStore.failSaving = true
        harness.viewModel.createTalkGroup()
        #expect(harness.viewModel.groups.isEmpty)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(!keys.values.isEmpty) // An uncommitted key is safe to sweep on reload.
        harness.groupStore.failSaving = false
        _ = try harness.viewModel.groupRepository.load(localMemberID: "member-local")
        #expect(keys.values.isEmpty)
        #expect(harness.viewModel.groups.isEmpty)
    }

    @Test func deletionRemovesKeyAndActiveInviteCannotReplaceKey() throws {
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        harness.viewModel.createTalkGroup()
        let group = try #require(harness.viewModel.selectedGroup)
        let saved = try harness.viewModel.groupRepository.credential(for: group.id)
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), credential: .init(groupID: group.id, secret: "other"),
                groupName: "Changed", inviterMemberID: "remote")
            #expect(throws: GroupInviteTokenError.activeGroupKeyChanged) {
                try harness.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
            }
        #expect(try harness.viewModel.groupRepository.credential(for: group.id) == saved)
        harness.viewModel.deleteGroup(group.id)
        #expect(try harness.viewModel.groupRepository.credential(for: group.id) == nil)
        #expect(harness.viewModel.groups.isEmpty)
    }

    @Test func fullGroupDoesNotEvictUnrelatedRiderForNewAuthenticatedMember() throws {
            let group = try IntercomGroup(
                name: "Eight", members: (0..<8).map { .init(id: "rider-\($0)", displayName: "Rider") },
                accessSecret: "fixture")
        let harness = AppTestSupport.makeHarness(groups: [group])
        harness.viewModel.selectGroup(group)
        harness.viewModel.connectedPeerIDs = (2..<8).map { "rider-\($0)" } + ["replacement"]
        harness.callSession.authenticate(["replacement"])
        let profile = try testPeerProfile(harness.viewModel, peerID: "replacement", displayName: "Replacement")
        harness.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "replacement", message:
            .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
        #expect(harness.viewModel.groups[0].members.count == 8)
        #expect(!harness.viewModel.groups[0].members.contains { $0.id == "replacement" })
        #expect(harness.viewModel.groups[0].members.contains { $0.id == "rider-1" })
    }

}
