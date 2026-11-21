import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension AccountDirectCallTests {
    @Test(arguments: [false, true]) func groupContactRegistrationUsesTheAccountCallForStartingAndResharing(
        existingCalls: Bool
    ) throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let author = try fixture.peer("author-phone", account: "a")
        let recipient = try fixture.peer("recipient-phone", account: "b")
        if existingCalls {
            try prepareExistingAccountCalls(fixture: fixture, author: author, recipient: recipient)
        }
        let groupID = try fixture.completeGroupContactRegistration(from: author, to: recipient)

        let authorPerson = try #require(author.viewModel.savedRemoteUsers.first)
        let recipientPerson = try #require(recipient.viewModel.savedRemoteUsers.first)
        let authorPrincipal = try #require(author.viewModel.localAccountPrincipal)
        let recipientPrincipal = try #require(recipient.viewModel.localAccountPrincipal)
        #expect(authorPerson.principal == recipientPrincipal)
        #expect(recipientPerson.principal == authorPrincipal)
        let expectedID = AccountCallPair(authorPrincipal, recipientPrincipal).id
        for (peer, person) in [(author, authorPerson), (recipient, recipientPerson)] {
            #expect(peer.viewModel.existingDirectCall(for: person.id)?.id == (existingCalls ? expectedID : nil))
            peer.viewModel.setRTCTransportRoutes([.multipeer])
        }
        if existingCalls {
            let settingsCall = try #require(author.viewModel.existingDirectCall(for: authorPerson.id))
            let url = try #require(author.viewModel.makeGroupInviteURL(for: settingsCall.id))
            let invite = try GroupInviteTokenCodec.decodeJoinURL(url)
            #expect(invite.groupID == expectedID)
            #expect(invite.recipientAccount == recipientPrincipal)
            #expect(invite.recipientMemberID == nil)
            try recipient.viewModel.acceptInviteURL(url)
        }

        for peer in [author, recipient] {
            let person = try #require(peer.viewModel.savedRemoteUsers.first)
            try #require(
                peer.viewModel.startCall(to: .user(person.id), accountAccessID: peer.viewModel.accountAccessID))
            #expect(peer.viewModel.existingDirectCall(for: person.id)?.id == expectedID)
            #expect(peer.viewModel.activeGroupID == expectedID)
        }
        let callID = try #require(author.viewModel.activeGroupID)
        let authorKey = try #require(try author.viewModel.groupRepository.credential(for: callID))
        let recipientKey = try #require(try recipient.viewModel.groupRepository.credential(for: callID))
        #expect(authorKey.secret != (try author.viewModel.groupRepository.credential(for: groupID)?.secret))
        #expect(authorKey.secret == recipientKey.secret)
    }

    private func prepareExistingAccountCalls(
        fixture: AccountCallFixture, author: AppTestSupport.Harness, recipient: AppTestSupport.Harness
    ) throws {
        try fixture.introduce(recipient, to: author)
        try fixture.introduce(author, to: recipient)
        for peer in [author, recipient] {
            peer.viewModel.disconnect()
            let person = try #require(peer.viewModel.savedRemoteUsers.first)
            try #require(peer.viewModel.selectUser(person.id, connectIfIdle: false))
        }
        let oldID = try #require(author.viewModel.selectedGroup?.id)
        #expect(recipient.viewModel.selectedGroup?.id == oldID)
        try recipient.viewModel.groupRepository.save(recipient.viewModel.groups,
            credential: .init(groupID: oldID, secret: "prior-account-call-fixture"))
        #expect(
            try author.viewModel.groupRepository.credential(for: oldID)
                != recipient.viewModel.groupRepository.credential(for: oldID))
    }

    @Test func expiredLocalCertificateKeepsStableIdentityButCannotIssueNewAccountInvitation() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a", at: Date().addingTimeInterval(-3600))
        let secondPeer = try testFixture.peer("b", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer)
        #expect(firstPeer.viewModel.localAccountPrincipal?.userID == String(repeating: "a", count: 64))
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        #expect(firstPeer.viewModel.selectedGroup?.accountPair != nil)
        #expect(firstPeer.viewModel.makeSelectedGroupInviteURL() == nil)
        #expect(firstPeer.viewModel.groupStorageIssue == nil)
        #expect(throws: (any Error).self) { try firstPeer.viewModel.internetSettingsStore.loadIdentity(memberID: "a") }
        #expect(
            try firstPeer.viewModel.internetSettingsStore.loadPrincipal(memberID: "a")
                == firstPeer.viewModel.localAccountPrincipal)
        #expect(throws: (any Error).self) {
            try firstPeer.viewModel.internetSettingsStore.loadPrincipal(memberID: "different")
        }
        try firstPeer.viewModel.internetSettingsStore.save(
            url: "https://account.test", token: "replacement-without-identity")
        #expect(try firstPeer.viewModel.internetSettingsStore.loadPrincipal(memberID: "a") == nil)
    }

    @Test(arguments: [false, true]) func signedOutInternetRegistrationKeepsOfflineCallIdentityAfterNativeLogin(
        peerHasCertificate: Bool
    ) throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"),
            secondPeer = try testFixture.peer("b", account: "b"),
            firstPeerSecondDevice = try testFixture.peer("a2", account: "a")
        try testFixture.introduce(secondPeer, to: firstPeer)
        try testFixture.introduce(firstPeerSecondDevice, to: firstPeer)
        let user = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        #expect(firstPeer.viewModel.selectUser(user.id))
        let group = try #require(firstPeer.viewModel.selectedGroup)
        let credential = try firstPeer.viewModel.groupRepository.credential(for: group.id)
        let count = firstPeer.viewModel.groups.count
        firstPeer.viewModel.disconnect()
        let store = firstPeer.viewModel.internetSettingsStore
        let retired = try #require(try store.retireAppleCredential())
        try store.finishRevocation(retired)
        let restarted = try testFixture.restart(firstPeer)
        #expect(restarted.viewModel.localAccountPrincipal == firstPeer.viewModel.localAccountPrincipal)
        #expect(!restarted.viewModel.hasInternetCredentials)
        #expect(try store.load() == nil && store.loadIdentity(memberID: "a") == nil)
        #expect(restarted.viewModel.savedRemoteUsers.map(\.id) == [user.id])
        #expect(restarted.viewModel.selectUser(user.id))
        #expect(restarted.viewModel.selectedGroup?.id == group.id)
        #expect(restarted.viewModel.groups.count == count)
        #expect(try restarted.viewModel.groupRepository.credential(for: group.id) == credential)
        #expect(restarted.viewModel.makeSelectedGroupInviteURL() == nil)
        restarted.callSession.authenticate(["b"])
        try testFixture.deliverProfile(from: secondPeer, to: restarted, certified: peerHasCertificate)
        #expect(restarted.viewModel.peerProfiles["b"]?.verified != nil)
        #expect(
            Set(IntercomViewModel.admittedMemberships(in: restarted.viewModel.peerProfiles).keys.map(\.rawValue))
                == ["b"])
        // Offline trust still verifies a current peer certificate. A new account
        // reusing the old device key must not inherit the old account's call.
        restarted.callSession.authenticate([]); restarted.callSession.authenticate(["b"])
        let key = try secondPeer.viewModel.internetSettingsStore.deviceSigningKey()
        let changed = try testIdentityCertificate(signer: testFixture.issuer, userID: String(repeating: "c", count: 64),
            memberID: "b", deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try changed.verify(
            origin: URL(string: "https://account.test")!, trustedIssuerKey: changed.issuerKey)
        let profile = try testPeerProfile(
            restarted.viewModel, peerID: "b", displayName: "Same device, different account",
            signer: DeviceIdentitySigner(memberID: "b", key: key, identity: identity))
        restarted.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "b",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
        #expect(restarted.viewModel.peerProfiles["b"]?.verified == nil)
    }

    @Test func missingLocalAccountIdentityCannotDowngradeASavedAccountCallToDeviceIDs() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"), secondPeer = try testFixture.peer("b", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer)
        let user = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        #expect(firstPeer.viewModel.selectUser(user.id))
        let original = firstPeer.groupStore.snapshot
        try firstPeer.viewModel.saveInternetConnection(
            url: "https://account.test", token: "manual-without-account-identity")
        #expect(firstPeer.viewModel.localAccountPrincipal == nil)
        #expect(!firstPeer.viewModel.selectUser(user.id))
        #expect(firstPeer.groupStore.snapshot == original)
        #expect(firstPeer.viewModel.groupErrorMessage?.contains("Verify your account") == true)
    }

    @Test(arguments: ["current", "signed-out", "manual"])
    func replacedPublicAccountStopsOldCallsAndKeepsDeletionTarget(source: String) throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"), secondPeer = try testFixture.peer("b", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer)
        let user = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        #expect(firstPeer.viewModel.selectUser(user.id))
        firstPeer.viewModel.connectLocal()
        #expect(firstPeer.viewModel.activeGroupID != nil)
        let before = firstPeer.groupStore.snapshot
        let store = firstPeer.viewModel.internetSettingsStore
        if source == "signed-out" {
            let retired = try #require(try store.retireAppleCredential())
            try store.finishRevocation(retired)
        } else if source == "manual" {
            try firstPeer.viewModel.saveInternetConnection(url: "https://account.test", token: "manual-token")
        }
        let key = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(
            signer: testFixture.issuer, userID: String(repeating: "c", count: 64),
            deviceID: store.accountDeviceID(), memberID: "a",
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation))
        let identity = try certificate.verify(
            origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey)
        #expect(throws: (any Error).self) {
            try firstPeer.viewModel.saveInternetConnection(
                url: "https://account.test", token: "replacement-token", identity: identity)
        }
        #expect(!firstPeer.viewModel.canStartCalls)
        #expect(firstPeer.viewModel.activeGroupID == nil)
        #expect(firstPeer.viewModel.localAccountPrincipal == nil)
        #expect(!firstPeer.viewModel.hasInternetCredentials)
        #expect(try store.load() == nil)
        #expect(try store.deletionAccess()?.userID == String(repeating: "a", count: 64))
        #expect(try store.deletionAccess()?.requiresAppleVerification == true)
        #expect(firstPeer.groupStore.snapshot == before)
        #expect(!firstPeer.viewModel.selectUser(user.id))
        firstPeer.viewModel.connectLocal()
        #expect(firstPeer.viewModel.activeGroupID == nil)
        let restarted = try testFixture.restart(firstPeer)
        #expect(!restarted.viewModel.canStartCalls)
        #expect(restarted.viewModel.accountSession.userID != nil)
        #expect(throws: (any Error).self) { try restarted.viewModel.makeInternetAccountAuthorization() }
        #expect(throws: (any Error).self) {
            try restarted.viewModel.saveInternetConnection(url: "https://another.test", token: "manual-token")
        }
    }

    @Test func schemaFiveUpgradePreservesSignedPendingReceiptAndCredential() throws {
        let testFixture = AccountCallFixture(); defer { testFixture.disconnect() }
        let firstPeer = try testFixture.peer("a", account: "a"), secondPeer = try testFixture.peer("b", account: "b")
        try testFixture.introduce(secondPeer, to: firstPeer)
        var old = firstPeer.groupStore.snapshot
        old.version = 5
        old.groupLinkReceipts = []
        for index in old.groups.indices {
            old.groups[index].accountDevices = [:]
            old.groups[index].invitationDeviceKeys = nil
        }
        let receipt = try #require(old.groups.first?.pendingInvitation)
        let upgraded = try GroupSnapshot.decode(old.encoded()).upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion)
        #expect(upgraded.groups.first?.pendingInvitation == receipt)
        #expect(upgraded.groups.first?.credentialReference == old.groups.first?.credentialReference)
        #expect(upgraded.users == old.users)
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        var invalid = firstPeer.groupStore.snapshot; invalid.version = 5
        invalid.groupLinkReceipts = []
        for index in invalid.groups.indices { invalid.groups[index].invitationDeviceKeys = nil }
        #expect(throws: (any Error).self) { try invalid.encoded() }
    }

    @Test func ownOtherDeviceCannotBecomeAnIndividualCallTarget() throws {
        let fixture = AccountCallFixture(); defer { fixture.disconnect() }
        let firstPeer = try fixture.peer("alice-phone", account: "a")
        let firstPeerSecondDevice = try fixture.peer("alice-tablet", account: "a")
        try fixture.introduce(firstPeerSecondDevice, to: firstPeer)
        let saved = try #require(firstPeer.viewModel.savedUsers.first)
        #expect(firstPeer.viewModel.savedRemoteUsers.isEmpty)
        #expect(!firstPeer.viewModel.selectUser(saved.id))
    }
}
