import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct PeerProfileTests {
    @Test func audioAdmissionRequiresCurrentProofAndSurvivesCodecChanges() throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        viewModel.selectGroup(try #require(viewModel.groups.first)); harness.callSession.authenticate(["member-108"])
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        let proof = try testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend")
        try deliver(proof, from: "member-108", to: viewModel)
        guard case .admittedMemberships(let admitted) = harness.callSession.audioPolicies.last?.peerPolicy else {
            Issue.record("Verified participants must use explicit RTC admission"); return
        }
        #expect(Set(admitted.keys.map(\.rawValue)) == ["member-108"])
        viewModel.updateAudioPipelineCodecSettings(); viewModel.rebuildAudioPipelineIfRunning()
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships(admitted))
        viewModel.handleTransportEvent(.connected(peerIDs: []))
        harness.callSession.authenticate([])
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        harness.callSession.authenticate(["member-108"])
        try deliver(proof, from: "member-108", to: viewModel)
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try deliver(
            testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend"), from: "member-108",
            to: viewModel)
        guard case .admittedMemberships(let fresh) = harness.callSession.audioPolicies.last?.peerPolicy else {
            Issue.record("Rejoined participant was not admitted"); return
        }
        #expect(fresh.count == 1 && fresh != admitted)
        viewModel.disconnect()
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
    }

    @Test func changedMembershipInvalidatesProofWithoutAnIntermediateEmptySnapshot() throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first)); harness.callSession.authenticate(["member-108"])
        let old = try testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend")
        try deliver(old, from: "member-108", to: viewModel)
        let fresh = UUID()
        viewModel.handleTransportEvent(
            .authenticated(members: [
                .init(
                    peer: .init(id: .init(rawValue: "member-108"), displayName: "Friend"),
            route: .webRTC, isConnected: true, membershipID: fresh)]))
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        #expect(viewModel.peerProfiles["member-108"]?.verified == nil)
        try deliver(old, from: "member-108", to: viewModel)
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try deliver(
            testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend"), from: "member-108",
            to: viewModel)
        let allowed = RTC.RTCAudioPeerPolicy.admittedMemberships([.init(rawValue: "member-108"): fresh])
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == allowed)
        let challenge = viewModel.peerProfiles["member-108"]?.challenge
        viewModel.handleTransportEvent(
            .authenticated(members: [
                .init(
                    peer: .init(id: .init(rawValue: "member-108"), displayName: "Friend"),
            route: .multipeer, isConnected: true, membershipID: fresh)]))
        #expect(viewModel.peerProfiles["member-108"]?.challenge == challenge)
        #expect(harness.callSession.audioPolicies.last?.peerPolicy == allowed)
    }

    @Test func twoPeersProveNamesWithoutCreatingGroupOnlyContactsAndKeepLocalNickname() throws {
        let alice = AppTestSupport.makeHarness(groups: [], localMemberID: "alice")
        let bob = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { alice.viewModel.disconnect(); bob.viewModel.disconnect() }
        #expect(alice.viewModel.createTalkGroup(name: "Friends"))
        try bob.viewModel.acceptInviteURL(#require(alice.viewModel.makeSelectedGroupInviteURL()))
        alice.callSession.authenticate(["bob"]); bob.callSession.authenticate(["alice"])
        var aliceIndex = 0, bobIndex = 0
        func pump() {
            for _ in 0..<8 {
                let old = aliceIndex + bobIndex
                while aliceIndex < alice.callSession.sentApplicationDataMessages.count {
                    let message = alice.callSession.sentApplicationDataMessages[aliceIndex]; aliceIndex += 1
                    bob.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "alice", message: message))
                }
                while bobIndex < bob.callSession.sentApplicationDataMessages.count {
                    let message = bob.callSession.sentApplicationDataMessages[bobIndex]; bobIndex += 1
                    alice.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: message))
                }
                if aliceIndex + bobIndex == old { return }
            }
            Issue.record("Profile exchange did not settle")
        }
        pump()
        #expect(alice.viewModel.peerProfiles["bob"]?.verified != nil)
        #expect(bob.viewModel.peerProfiles["alice"]?.verified != nil)
        let user = try #require(alice.viewModel.savedUsers.first)
        #expect(alice.viewModel.renameSavedUser(user.id, displayName: "My Friend"))
        #expect(bob.viewModel.setLocalDisplayName("Bob's new name"))
        pump()
        #expect(alice.viewModel.savedUsers.first?.displayName == "Bob's new name")
        #expect(alice.viewModel.savedUsers.first?.resolvedDisplayName == "My Friend")
        alice.callSession.authenticate(["bob", "group-only"])
        let stranger = try testPeerProfile(alice.viewModel, peerID: "group-only", displayName: "Today's Rider")
        try deliver(stranger, from: "group-only", to: alice.viewModel)
        #expect(alice.viewModel.savedUsers.count == 1)
        #expect(alice.viewModel.peerProfiles["group-only"]?.verified != nil)
    }

    @Test func copiedMemberIDCannotReplaceSavedKeyAndOldConnectionCannotReplayAName() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "local")
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            groupID: UUID(), groupName: "Friends", groupSecret: "group-key", inviterMemberID: "friend",
            inviterDisplayName: "Friend")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        harness.callSession.authenticate(["friend"])
        let forged = try testPeerProfile(viewModel, peerID: "friend", displayName: "Impostor",
            signer: DeviceIdentitySigner(memberID: "friend", key: P256.Signing.PrivateKey()))
        try deliver(forged, from: "friend", to: viewModel)
        #expect(
            viewModel.savedUsers.first?.displayName == "Friend"
                && viewModel.peerProfiles["friend"]?.verified == nil)
        #expect(viewModel.groupStorageIssue == nil)
        let genuine = try testPeerProfile(viewModel, peerID: "friend", displayName: "Current", revision: 2)
        try deliver(genuine, from: "friend", to: viewModel)
        let stale = try testPeerProfile(viewModel, peerID: "friend", displayName: "Old name", revision: 1)
        let writes = harness.groupStore.saveCount
        try deliver(stale, from: "friend", to: viewModel); try deliver(genuine, from: "friend", to: viewModel)
        #expect(viewModel.savedUsers.first?.displayName == "Current" && harness.groupStore.saveCount == writes)
        viewModel.handleTransportEvent(.connected(peerIDs: [])); harness.callSession.authenticate(["friend"])
        #expect(viewModel.peerProfiles["friend"]?.verified == nil)
        try deliver(genuine, from: "friend", to: viewModel)
        #expect(viewModel.peerProfiles["friend"]?.verified == nil)
        let current = try testPeerProfile(viewModel, peerID: "friend", displayName: "Reconnected", revision: 1)
        try deliver(current, from: "friend", to: viewModel)
        #expect(viewModel.savedUsers.first?.displayName == "Reconnected")
        viewModel.disconnect(); viewModel.connectLocal(); harness.callSession.authenticate(["friend"])
        try deliver(current, from: "friend", to: viewModel)
        #expect(viewModel.peerProfiles["friend"]?.verified == nil)
    }

    @Test func challengeBackoffStopsAfterVerificationAndCachedRepliesDoNotReadKeys() throws {
        let keychain = DictionaryKeychain()
        let harness = AppTestSupport.makeHarness(
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: "profile-cache"))
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first)); harness.callSession.authenticate(["member-108"])
        let next = try #require(viewModel.peerProfiles["member-108"]).nextRequestAt
        let count = harness.callSession.sentApplicationDataMessages.count
        for _ in 0..<30 { viewModel.sendPeerProfileChallenges(now: next - 0.1) }
        #expect(harness.callSession.sentApplicationDataMessages.count == count)
        viewModel.sendPeerProfileChallenges(now: next)
        #expect(harness.callSession.sentApplicationDataMessages.count == count + 1)
        #expect(viewModel.peerProfiles["member-108"]?.requestInterval == 4)
        let nonce = UUID()
        try receiveTestProfileChallenge(viewModel, peerID: "member-108", nonce: nonce, now: 100)
        let reads = keychain.readCount, replyCount = harness.callSession.sentApplicationDataMessages.count
        let reply = try #require(harness.callSession.sentApplicationDataMessages.last)
        for _ in 0..<30 { try receiveTestProfileChallenge(viewModel, peerID: "member-108", nonce: UUID(), now: 100.5) }
        #expect(keychain.readCount == reads && harness.callSession.sentApplicationDataMessages.count == replyCount)
        try receiveTestProfileChallenge(viewModel, peerID: "member-108", nonce: nonce, now: 102)
        #expect(keychain.readCount == reads)
        #expect(harness.callSession.sentApplicationDataMessages.last?.payload == reply.payload)
        try deliver(
            testPeerProfile(viewModel, peerID: "member-108", displayName: "Verified"), from: "member-108",
            to: viewModel)
        let verifiedCount = harness.callSession.sentApplicationDataMessages.count
        viewModel.sendPeerProfileChallenges(now: next + 600)
        #expect(harness.callSession.sentApplicationDataMessages.count == verifiedCount)
        viewModel.disconnect(); #expect(viewModel.peerProfiles.isEmpty)
    }

    @Test func changedPayloadAndWrongRecipientCannotPassVerification() throws {
        let nonce = UUID(), group = UUID()
        let original = try SharedDisplayName.make(groupID: group, recipientMemberID: "local", challenge: nonce,
            revision: 1, displayName: "Friend", signer: testIdentitySigner("friend"))
        let encoded = try JSONEncoder().encode(original)
        let values: [(String, Any)] = [("displayName", "Spoofed"), ("revision", 2), ("memberID", "other"),
            ("recipientMemberID", "other"), ("challenge", UUID().uuidString), ("groupID", UUID().uuidString)]
        for (field, value) in values {
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object[field] = value
            let changed = try JSONDecoder().decode(
                SharedDisplayName.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(throws: (any Error).self) {
                try changed.verified(peerID: "friend", recipient: "local", groupID: group, challenge: nonce)
            }
        }
        #expect(
            try original.verified(peerID: "friend", recipient: "local", groupID: group, challenge: nonce)
                .displayName == "Friend")
    }

    @Test func certifiedAccountChangeCannotRenameThePreviousAccountEvenWithSameDeviceKey() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let issuer = P256.Signing.PrivateKey(), device = TestDeviceIdentities.key("friend")
        let trust = DeviceIdentityTrust(
            origin: try #require(URL(string: "https://account.test")),
            issuerKey: IdentityEncoding.encode(issuer.publicKey.x963Representation))
        func signer(_ user: String) throws -> DeviceIdentitySigner {
            let certificate = try testIdentityCertificate(
                signer: issuer, userID: String(repeating: user, count: 64), memberID: "friend",
                deviceKey: IdentityEncoding.encode(device.publicKey.x963Representation))
            return try DeviceIdentitySigner(memberID: "friend", key: device,
                identity: certificate.verify(origin: trust.origin, trustedIssuerKey: trust.issuerKey))
        }
        let original = try signer("a")
        let group = try IntercomGroup(
            name: "Friends",
            members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: original, groupID: group.id,
            groupName: group.name, groupSecret: "key", inviterMemberID: "friend", inviterDisplayName: "Friend")
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: token.accept(signer: testIdentitySigner("local"), displayName: "You", trust: trust))
        let nonce = UUID()
        for user in ["a", "b"] {
            let value = try SharedDisplayName.make(groupID: group.id, recipientMemberID: "local", challenge: nonce,
                revision: 1, displayName: user, signer: signer(user))
            let verified = try value.verified(
                peerID: "friend", recipient: "local", groupID: group.id, challenge: nonce, trust: trust)
            #expect(verified.identity.principal?.userID == String(repeating: user, count: 64))
            #expect(try fixture.repository.receiveProfile(verified) == (user == "a"))
        }
        #expect(fixture.repository.users.first?.displayName == "a")
        #expect(fixture.repository.users.first?.principal?.userID == String(repeating: "a", count: 64))
        #expect(
            try !fixture.repository.receiveProfile(
                testVerifiedPeerProfile(groupID: group.id, memberID: "unknown", displayName: "Ignored")))
        #expect(
            try !fixture.repository.receiveProfile(
                testVerifiedPeerProfile(groupID: UUID(), memberID: "friend", displayName: "Ignored")))
    }

    @Test(arguments: ["link", "disconnect", "signout"])
    func losingTheConnectionDiscardsProfileProofs(reason: String) throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: account.session)
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first)); harness.callSession.authenticate(["member-108"])
        let value = try testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend")
        try deliver(value, from: "member-108", to: viewModel)
        #expect(viewModel.peerProfiles["member-108"]?.verified != nil)
        switch reason {
        case "link": viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        case "disconnect": viewModel.handleTransportEvent(.disconnected)
        default: account.session.signOut(); account.signIn()
        }
        #expect(viewModel.peerProfiles.isEmpty)
        try deliver(value, from: "member-108", to: viewModel)
        #expect(viewModel.peerProfiles.isEmpty)
    }

    private func deliver(_ profile: SharedDisplayName, from peerID: String, to viewModel: IntercomViewModel) throws {
        viewModel.handleTransportEvent(.receivedApplicationData(peerID: peerID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
    }
}
