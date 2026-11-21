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

extension AppTests {
@MainActor
struct GroupLifecycleTests {
    @Test(arguments: [false, true])
    func leavingAGroupDoesNotAllowPreviouslyAcceptedLinksToRestoreIt(legacySnapshot: Bool) throws {
        var now = Date().timeIntervalSince1970
            let harness = AppTestSupport.makeHarness(
                groups: [], localMemberID: "local", callAccessNow: { Date(timeIntervalSince1970: now) })
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let signer = testIdentitySigner("remote"), authority = testInvitationAuthority(), groupID = UUID()
        func link(secret: String) throws -> URL {
            try GroupInviteTokenCodec.joinURL(for: GroupInviteToken.make(authority: authority, signer: signer,
                groupID: groupID, groupName: "Ride", groupSecret: secret, inviterMemberID: signer.memberID,
                issuedAt: now, expiresAt: now + 60))
        }

        let oldLinks = try [link(secret: "first-key"), link(secret: "first-key")]
        for url in oldLinks { try viewModel.acceptInviteURL(url, now: now) }
        let receipt = try #require(viewModel.groupRepository.pendingInvitation(for: groupID))
        let acknowledgement = try receipt.acknowledged(by: signer)
        #expect(try viewModel.groupRepository.acknowledgeInvitation(acknowledgement))
        #expect(try !viewModel.groupRepository.acknowledgeInvitation(acknowledgement))
        #expect(viewModel.groupRepository.pendingInvitation(for: groupID) == nil)
        let contact = try #require(viewModel.savedRemoteUsers.first)
        if legacySnapshot {
            viewModel.disconnect()
                var json = try #require(
                    JSONSerialization.jsonObject(with: harness.groupStore.snapshot.encoded()) as? [String: Any])
            json["version"] = 15
            json.removeValue(forKey: "groupLinkReceipts")
            harness.groupStore.snapshot = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json))
            viewModel.reloadSavedGroups()
        }
        let beforeFailedLeave = harness.groupStore.snapshot, callBeforeFailedLeave = viewModel.currentCallReference
        harness.groupStore.failSaving = true
        viewModel.deleteGroup(groupID)
        #expect(harness.groupStore.snapshot == beforeFailedLeave)
        #expect(viewModel.currentCallReference == callBeforeFailedLeave)
        harness.groupStore.failSaving = false
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        viewModel.selectGroup(try #require(viewModel.groups.first { $0.id == groupID }))
        #expect(viewModel.activeGroupID == groupID)
        viewModel.deleteGroup(groupID)
        #expect(viewModel.activeGroupID == nil && harness.callSession.connectedGroup == nil)
        harness.groupStore.snapshot = try GroupSnapshot.decode(harness.groupStore.snapshot.encoded())
        viewModel.reloadSavedGroups()
        #expect(viewModel.groups.allSatisfy { $0.id != groupID })
        #expect(try viewModel.groupRepository.credential(for: groupID) == nil)
        #expect(viewModel.savedRemoteUsers.map(\.id) == [contact.id])

        #expect(viewModel.createTalkGroup(name: "Keep this call"))
        let currentCall = viewModel.currentCallReference, beforeReplay = harness.groupStore.snapshot
        for url in oldLinks {
            #expect(throws: GroupInviteTokenError.retiredGroupLink) { try viewModel.acceptInviteURL(url, now: now) }
            #expect(viewModel.currentCallReference == currentCall)
        }
        #expect(harness.groupStore.snapshot == beforeReplay)
        #expect(viewModel.groupStorageIssue == nil)
        #expect(viewModel.inviteStatusMessage == nil)
            #expect(
                viewModel.groupErrorMessage
                    == "This link was already used to join this group. Ask the sender for a new invitation.")

        viewModel.disconnect()
        try viewModel.acceptInviteURL(link(secret: "fresh-key"), now: now)
        #expect(try viewModel.groupRepository.credential(for: groupID)?.secret == "fresh-key")
        let rejoined = viewModel.currentCallReference
        #expect(throws: GroupInviteTokenError.retiredGroupLink) { try viewModel.acceptInviteURL(oldLinks[0], now: now) }
        #expect(viewModel.currentCallReference == rejoined)
        viewModel.disconnect()
            for url in oldLinks {
                #expect(throws: GroupInviteTokenError.retiredGroupLink) { try viewModel.acceptInviteURL(url, now: now) }
            }
        #expect(try viewModel.groupRepository.credential(for: groupID)?.secret == "fresh-key")
        now += 61
        viewModel.deleteGroup(groupID)
        #expect(harness.groupStore.snapshot.groupLinkReceipts.count == (legacySnapshot ? 2 : 0))
    }

    @Test func invitationStorageFailureKeepsStorageRecoveryInsteadOfRequestingAnotherInvite() throws {
        let harness = AppTestSupport.makeHarness(groups: [])
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"),
            groupID: UUID(), groupName: "Ride", groupSecret: "shared", inviterMemberID: "remote")
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        try harness.viewModel.acceptInviteURL(url)
        let activeID = harness.viewModel.activeGroupID
        let saves = harness.groupStore.saveCount
            harness.groupStore.readError = DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "broken stored snapshot"))
        #expect(throws: (any Error).self) { try harness.viewModel.acceptInviteURL(url) }
        #expect(harness.viewModel.groupStorageIssue == .corrupted)
        #expect(harness.viewModel.groupErrorMessage == GroupStorageIssue.corrupted.message)
        #expect(harness.viewModel.inviteStatusMessage == nil)
        #expect(harness.viewModel.activeGroupID == activeID)
        #expect(harness.groupStore.saveCount == saves)
        #expect(harness.callSession.disconnectCallCount == 0)
        harness.groupStore.readError = nil
        harness.viewModel.disconnect()
        harness.viewModel.reloadSavedGroups()
        try harness.viewModel.acceptInviteURL(url)
        #expect(harness.viewModel.groupStorageIssue == nil)
        #expect(harness.viewModel.groupErrorMessage == nil)
        #expect(harness.viewModel.inviteStatusMessage == "JOINED Ride")
    }

    @Test(arguments: ["expired", "version", "signature", "malformed"])
    func failedInvitationClearsSuccessExplainsRecoveryAndAcceptsReplacement(_ failure: String) throws {
        let harness = AppTestSupport.makeHarness(groups: [])
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"),
            groupID: UUID(), groupName: "Ride", groupSecret: "shared", inviterMemberID: "remote",
            issuedAt: 100, expiresAt: 200)
        let validURL = try GroupInviteTokenCodec.joinURL(for: token)
        try harness.viewModel.acceptInviteURL(validURL, now: 150)
        let groupIDs = harness.viewModel.groups.map(\.id)
        let activeID = harness.viewModel.activeGroupID
        let saves = harness.groupStore.saveCount
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        let expected: String
        switch failure {
        case "expired":
            expected = "This invitation has expired. Ask the sender for a new invitation."
        case "version":
            object["version"] = 999
            expected = "This invitation uses a different app version. Update RideCom and ask for a new invitation."
        default:
            object["signature"] = "invalid"
            expected = "This invitation could not be verified. Ask the sender for a new invitation."
        }
        let encoded = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            let badURL = try #require(
                URL(string: "rideintercom://join?token=\(failure == "malformed" ? "broken" : encoded)"))
        #expect(throws: (any Error).self) { try harness.viewModel.acceptInviteURL(badURL, now: 200) }
        #expect(harness.viewModel.groupErrorMessage == expected)
        #expect(harness.viewModel.inviteStatusMessage == nil)
        #expect(harness.viewModel.groups.map(\.id) == groupIDs)
        #expect(harness.viewModel.activeGroupID == activeID)
        #expect(harness.groupStore.saveCount == saves)
        #expect(harness.callSession.disconnectCallCount == 0)

            let replacement = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"),
            groupID: token.groupID, groupName: "Ride", groupSecret: "shared", inviterMemberID: "remote",
            issuedAt: 200, expiresAt: 300)
        try harness.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: replacement), now: 250)
        #expect(harness.viewModel.groupErrorMessage == nil)
        #expect(harness.viewModel.inviteStatusMessage == "JOINED Ride")
        #expect(harness.viewModel.activeGroupID == activeID)
    }

    @Test func corruptLocalIdentityReportsCreationFailureWithoutWritingGroups() {
        var stored = IntercomSeedData.recentGroups[0]
        stored.members[0] = GroupMember(id: "", displayName: "You")
        let harness = AppTestSupport.makeHarness(groups: [stored])
        harness.viewModel.createTalkGroup()
        #expect(harness.viewModel.groupErrorMessage != nil)
        #expect(harness.viewModel.groups.isEmpty)
        #expect(harness.groupStore.snapshot.groups.count == 1)
        #expect(harness.groupStore.saveCount == 0)
    }

    @Test func groupInviteTokenRoundTripsAndRejectsTampering() throws {
        let groupID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("member-001"),
            groupID: groupID,
            groupName: "Talk Group",
            groupSecret: "talk-secret",
            inviterMemberID: "member-001",
            issuedAt: 100,
            expiresAt: 200
        )

        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url)
        let tampered = try GroupInviteToken(
            version: decoded.version,
            groupID: decoded.groupID,
            groupName: "Other Group",
            groupSecret: decoded.groupSecret,
            inviterMemberID: decoded.inviterMemberID,
            issuedAt: decoded.issuedAt,
            expiresAt: decoded.expiresAt,
            directInvitation: decoded.directInvitation,
            signature: decoded.signature
        )

        #expect(url.absoluteString.hasPrefix("rideintercom://join?token="))
        #expect(decoded == token)
        #expect(decoded.verifySignature())
        #expect(!tampered.verifySignature())
        #expect(!token.isExpired(now: 199.9))
        #expect(token.isExpired(now: 200))
    }

    @Test func viewModelCreatesAndPersistsTalkGroupWithoutTestMode() {
        let harness = AppTestSupport.makeHarness(groups: [])

        harness.viewModel.createTalkGroup()

        #expect(harness.viewModel.groups.count == 1)
        #expect(harness.viewModel.selectedGroup?.name == "Talk Group")
        #expect(harness.viewModel.activeGroupID == harness.viewModel.selectedGroup?.id)
        #expect(harness.callSession.connectedGroup?.id == harness.viewModel.selectedGroup?.id)
        #expect(harness.groupStore.loadGroups().map(\.name) == ["Talk Group"])
    }

    @Test func viewModelAcceptsInviteURLAndStoresCredential() throws {
        let credentialStore = InMemoryGroupCredentialStore()
        let groupID = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
            let token = try GroupInviteToken.make(
                authority: testInvitationAuthority(), signer: testIdentitySigner("member-remote"),
            groupID: groupID,
            groupName: "Invited Group",
            groupSecret: "shared-secret",
            inviterMemberID: "member-remote",
            issuedAt: 100,
            expiresAt: 200
        )
        let url = try GroupInviteTokenCodec.joinURL(for: token)
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: credentialStore)

        try harness.viewModel.acceptInviteURL(url, now: 150)

        #expect(harness.viewModel.selectedGroup?.id == groupID)
        #expect(harness.viewModel.inviteStatusMessage == "JOINED Invited Group")
        #expect(try harness.viewModel.groupRepository.credential(for: groupID)?.secret == "shared-secret")
    }

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
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: UUID(),
                groupName: "Invite", groupSecret: "shared", inviterMemberID: "remote")
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
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: group.id,
                groupName: group.name, groupSecret: "", inviterMemberID: "remote")
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
                authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: group.id,
                groupName: "Changed", groupSecret: "other", inviterMemberID: "remote")
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
}
