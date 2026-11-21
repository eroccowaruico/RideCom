import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor final class AccountCallFixture {
    let issuer = P256.Signing.PrivateKey()
    var peers: [AppTestSupport.Harness] = []
    var namespaces: [String] = []
    var credentialStores: [String: InMemoryGroupCredentialStore] = [:]
    func peer(_ memberID: String, account: String, at date: Date = Date()) throws -> AppTestSupport.Harness {
        let namespace = "RideIntercom.AccountCallTests." + UUID().uuidString
        namespaces.append(namespace)
        let store = InternetConnectionSettingsStore(keychain: DictionaryKeychain(), namespace: namespace)
        let key = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(signer: issuer, userID: String(repeating: account, count: 64),
            deviceID: store.accountDeviceID(), memberID: memberID,
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), now: date)
        let identity = try certificate.verify(
            origin: URL(string: "https://account.test")!, trustedIssuerKey: certificate.issuerKey, now: date)
        try store.save(
            url: "https://account.test",
            token:
                "ri1.\(String(repeating: "d", count: 64)).\(identity.deviceID).\(String(repeating: "e", count: 64))",
            identity: identity)
        let credentials = InMemoryGroupCredentialStore()
        credentialStores[memberID] = credentials
        let testHarness = AppTestSupport.makeHarness(
            groups: [], credentialStore: credentials, internetSettingsStore: store, localMemberID: memberID)
        peers.append(testHarness)
        return testHarness
    }
    func restart(_ previous: AppTestSupport.Harness) throws -> AppTestSupport.Harness {
        let memberID = previous.viewModel.localMemberIdentity.memberID
        let credentials = try #require(credentialStores[memberID])
        let testHarness = AppTestSupport.makeHarness(
            groups: [], groupStore: previous.groupStore, credentialStore: credentials,
            internetSettingsStore: previous.viewModel.internetSettingsStore, localMemberID: memberID)
        peers.append(testHarness)
        return testHarness
    }
    func introduce(_ sender: AppTestSupport.Harness, to receiver: AppTestSupport.Harness) throws {
        #expect(sender.viewModel.createTalkGroup(name: "Friends"))
        try receiver.viewModel.acceptInviteURL(#require(sender.viewModel.makeSelectedGroupInviteURL()))
    }
    func completeGroupContactRegistration(
        from author: AppTestSupport.Harness, to recipient: AppTestSupport.Harness
    ) throws -> UUID {
        author.viewModel.contactSessionFactory = { RecordingCallSession() }
        recipient.viewModel.contactSessionFactory = { RecordingCallSession() }
        let groupID = UUID()
        let draft = GroupInvitationDraft(name: "Other rider", suggestedName: "New person")
        try #require(
            author.viewModel.saveGroupInvitations(
                groupID: groupID, creating: true, name: "Mountain riders", selected: [], newPeople: [draft])
                == groupID)
        author.viewModel.disconnect()
        let share = try author.viewModel.prepareContactPersonShare(
            draft.id, expectedAccountAccessID: author.viewModel.accountAccessID)
        try recipient.viewModel.acceptContactInviteURL(share.url)
        let reply = try recipient.viewModel.contactReplyURLForSharing(
            share.id, expectedAccountAccessID: recipient.viewModel.accountAccessID)
        try author.viewModel.receiveContactReplyURL(reply)
        let acknowledgement = try author.viewModel.contactReplyURLForSharing(
            share.id, expectedAccountAccessID: author.viewModel.accountAccessID)
        try recipient.viewModel.receiveContactReplyURL(acknowledgement)
        return groupID
    }
    func deliverProfile(
        from sender: AppTestSupport.Harness, to receiver: AppTestSupport.Harness, certified: Bool = true
    ) throws {
        let memberID = sender.viewModel.localMemberIdentity.memberID
        let store = sender.viewModel.internetSettingsStore
        let signer = try certified ? store.invitationSigner(memberID: memberID)
            : DeviceIdentitySigner(memberID: memberID, key: store.deviceSigningKey())
        let profile = try testPeerProfile(
            receiver.viewModel, peerID: memberID, displayName: "Same name", signer: signer)
        receiver.viewModel.handleTransportEvent(.receivedApplicationData(peerID: memberID,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile))))
    }
    func disconnect() {
        peers.forEach { $0.viewModel.disconnect() }
        namespaces.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
    }
}
