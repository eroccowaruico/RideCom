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
        if legacySnapshot { try reopenLegacySnapshot(harness) }
        try verifyLeavingGroup(harness: harness, groupID: groupID)
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

    private func reopenLegacySnapshot(_ harness: AppTestSupport.Harness) throws {
        let viewModel = harness.viewModel
        viewModel.disconnect()
        var json = try #require(
            JSONSerialization.jsonObject(with: harness.groupStore.snapshot.encoded()) as? [String: Any])
        json["version"] = 15
        json.removeValue(forKey: "groupLinkReceipts")
        harness.groupStore.snapshot = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        viewModel.reloadSavedGroups()
    }

    private func verifyLeavingGroup(harness: AppTestSupport.Harness, groupID: UUID) throws {
        let viewModel = harness.viewModel
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

}
}
