import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct AccountDirectCallTests {
    @Test func multipleDevicesResolveOneCallAndAccountAddressAcceptsAnotherDevice() throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let firstPeer = try fixture.peer("alice-phone", account: "a")
        let secondPeer = try fixture.peer("bob-phone", account: "b")
        let secondPeerSecondDevice = try fixture.peer("bob-tablet", account: "b")
        let thirdPeer = try fixture.peer("charlie", account: "c")
        try fixture.introduce(secondPeer, to: firstPeer); try fixture.introduce(secondPeerSecondDevice, to: firstPeer)
        try fixture.introduce(firstPeer, to: secondPeerSecondDevice)
        let user = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        #expect(user.memberIDs.count == 2)
        firstPeer.viewModel.disconnect()
        #expect(firstPeer.viewModel.selectUser(user.id))
        let direct = try #require(firstPeer.viewModel.selectedGroup)
        #expect(direct.kind == .direct)
        let url = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL())
        try secondPeerSecondDevice.viewModel.acceptInviteURL(url)
        #expect(secondPeerSecondDevice.viewModel.selectedGroup?.kind == .direct)
        #expect(secondPeerSecondDevice.viewModel.selectedGroup?.id == direct.id)
        #expect(
            try firstPeer.viewModel.groupRepository.credential(for: direct.id)
                == secondPeerSecondDevice.viewModel.groupRepository.credential(for: direct.id))
        #expect(
            secondPeerSecondDevice.viewModel.selectUser(
                try #require(secondPeerSecondDevice.viewModel.savedRemoteUsers.first).id))
        #expect(secondPeerSecondDevice.viewModel.selectedGroup?.id == direct.id)
        let snapshot = thirdPeer.groupStore.snapshot
        #expect(throws: GroupInviteTokenError.wrongRecipient) { try thirdPeer.viewModel.acceptInviteURL(url) }
        #expect(thirdPeer.groupStore.snapshot == snapshot)
    }

    @Test func onlyTheOtherAccountCanEnrollADeviceAndRemovalEndsTheAccountCall() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"), secondPeer = try testFixture.peer("b", account: "b")
        let secondPeerSecondDevice = try testFixture.peer("b2", account: "b"),
            thirdPeer = try testFixture.peer("c", account: "c")
        let firstPeerSecondDevice = try testFixture.peer("a2", account: "a")
        try testFixture.introduce(secondPeer, to: firstPeer)
        let user = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        firstPeer.viewModel.disconnect()
        #expect(firstPeer.viewModel.selectUser(user.id))
        let groupID = try #require(firstPeer.viewModel.selectedGroup?.id)
        let key = try firstPeer.viewModel.groupRepository.credential(for: groupID)
        firstPeer.callSession.authenticate(["b2", "c", "a2", "unverified"])
        #expect(firstPeer.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        try testFixture.deliverProfile(from: thirdPeer, to: firstPeer)
        try testFixture.deliverProfile(from: firstPeerSecondDevice, to: firstPeer)
        try testFixture.deliverProfile(from: secondPeerSecondDevice, to: firstPeer)
        let unverified = try testPeerProfile(firstPeer.viewModel, peerID: "unverified", displayName: "Same name")
        firstPeer.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "unverified",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(unverified))))
        #expect(
            Set(IntercomViewModel.admittedMemberships(in: firstPeer.viewModel.peerProfiles).keys.map(\.rawValue))
                == ["b2"])
        #expect(Set(try #require(firstPeer.viewModel.selectedGroup).members.map(\.id)) == ["a", "b", "b2"])
        #expect(firstPeer.viewModel.savedUsers.first?.memberIDs == ["b"])
        firstPeer.callSession.authenticate([]); firstPeer.callSession.authenticate(["b2"])
        // No current account certificate: the earlier verified key is sufficient offline.
        try testFixture.deliverProfile(from: secondPeerSecondDevice, to: firstPeer, certified: false)
        #expect(firstPeer.viewModel.peerProfiles["b2"]?.verified != nil)
        #expect(try firstPeer.viewModel.groupRepository.credential(for: groupID) == key)
        firstPeer.callSession.authenticate([]); firstPeer.callSession.authenticate(["b2"])
        let forged = try testPeerProfile(firstPeer.viewModel, peerID: "b2", displayName: "Same name",
            signer: DeviceIdentitySigner(memberID: "b2", key: P256.Signing.PrivateKey()))
        firstPeer.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(forged))))
        #expect(firstPeer.viewModel.peerProfiles["b2"]?.verified == nil)
        // Same device key, but now certified as another account, must not inherit access.
        let b2key = try secondPeerSecondDevice.viewModel.internetSettingsStore.deviceSigningKey()
        let changed = try testIdentityCertificate(signer: testFixture.issuer, userID: String(repeating: "c", count: 64),
            memberID: "b2", deviceKey: IdentityEncoding.encode(b2key.publicKey.x963Representation))
        let changedProfile = try testPeerProfile(firstPeer.viewModel, peerID: "b2", displayName: "Same name",
            signer: DeviceIdentitySigner(memberID: "b2", key: b2key,
                identity: changed.verify(
                    origin: URL(string: "https://account.test")!, trustedIssuerKey: changed.issuerKey)))
        firstPeer.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(changedProfile))))
        #expect(firstPeer.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(firstPeer.viewModel.groupStorageIssue == nil)
        // The person and their account call are one: deleting them ends and removes the call.
        #expect(firstPeer.viewModel.removeSavedUser(user.id))
        #expect(firstPeer.viewModel.savedUsers.isEmpty)
        #expect(firstPeer.viewModel.activeGroupID == nil && firstPeer.viewModel.selectedGroup == nil)
        #expect(!firstPeer.viewModel.groups.contains { $0.id == groupID })
        #expect(try firstPeer.viewModel.groupRepository.credential(for: groupID) == nil)
    }

    @Test func foreignCertificationAndFailedPersistenceNeverGrantAudio() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"), secondPeer = try testFixture.peer("b", account: "b")
        let secondPeerSecondDevice = try testFixture.peer("b2", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer)
        firstPeer.viewModel.disconnect()
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        let id = try #require(firstPeer.viewModel.selectedGroup?.id)
        let key = try firstPeer.viewModel.groupRepository.credential(for: id)
        let old = firstPeer.groupStore.snapshot
        firstPeer.callSession.authenticate(["b2"])
        let deviceKey = try secondPeerSecondDevice.viewModel.internetSettingsStore.deviceSigningKey()
        let foreign = try testIdentityCertificate(
            signer: P256.Signing.PrivateKey(), userID: String(repeating: "b", count: 64),
            memberID: "b2", deviceKey: IdentityEncoding.encode(deviceKey.publicKey.x963Representation))
        let forged = try testPeerProfile(firstPeer.viewModel, peerID: "b2", displayName: "Friend",
            signer: DeviceIdentitySigner(memberID: "b2", key: deviceKey,
                identity: foreign.verify(
                    origin: URL(string: "https://account.test")!, trustedIssuerKey: foreign.issuerKey)))
        firstPeer.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b2",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(forged))))
        #expect(firstPeer.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(firstPeer.groupStore.snapshot == old)
        firstPeer.groupStore.failSaving = true
        try testFixture.deliverProfile(from: secondPeerSecondDevice, to: firstPeer)
        #expect(firstPeer.groupStore.snapshot == old)
        #expect(firstPeer.viewModel.selectedGroup?.id == id)
        #expect(firstPeer.viewModel.peerProfiles["b2"]?.verified == nil)
        #expect(firstPeer.callSession.audioPolicies.last?.peerPolicy == .admittedMemberships([:]))
        firstPeer.groupStore.failSaving = false
        // Reload reopens the repository after an uncertain commit failure.
        _ = try firstPeer.viewModel.groupRepository.load(localMemberID: "a")
        #expect(try firstPeer.viewModel.groupRepository.credential(for: id) == key)
    }

    @Test func simultaneousInvitationsConvergeByAccountInsteadOfDeviceOrdering() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("z-device", account: "a"),
            secondPeer = try testFixture.peer("a-device", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer); try testFixture.introduce(firstPeer, to: secondPeer)
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        #expect(secondPeer.viewModel.selectUser(try #require(secondPeer.viewModel.savedRemoteUsers.first).id))
        let id = try #require(firstPeer.viewModel.selectedGroup?.id)
        let originalA = try firstPeer.viewModel.groupRepository.credential(for: id)
        let originalB = try secondPeer.viewModel.groupRepository.credential(for: id)
        let initiallyMatched = originalA != nil && originalA == originalB
        #expect(initiallyMatched)
        try secondPeer.viewModel.groupRepository.save(
            secondPeer.viewModel.groups, credential: .init(groupID: id, secret: "conflicting-account-call-fixture"))
        let firstInviteURL = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL()),
            secondInviteURL = try #require(secondPeer.viewModel.makeSelectedGroupInviteURL())
        let winner = try firstPeer.viewModel.groupRepository.credential(for: id)
        firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect()
        try firstPeer.viewModel.acceptInviteURL(secondInviteURL)
        try secondPeer.viewModel.acceptInviteURL(firstInviteURL)
        #expect(try firstPeer.viewModel.groupRepository.credential(for: id) == winner)
        #expect(try secondPeer.viewModel.groupRepository.credential(for: id) == winner)
    }

}
