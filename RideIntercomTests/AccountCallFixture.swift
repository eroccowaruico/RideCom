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

@MainActor
struct ReplacementScenario {
    let fixture = AccountCallFixture()
    let other: AppTestSupport.Harness
    let replacement: AppTestSupport.Harness
    let groupID: UUID
    let directID: UUID
    let savedPersonID: UUID
    let backup: GroupSnapshot
    let backupOwner: AccountDeviceBinding
    let oldSigner: DeviceIdentitySigner
    let trust: DeviceIdentityTrust
    let restoredCredentials = InMemoryGroupCredentialStore()

    init() throws {
        let old = try fixture.peer("alice-old", account: "a")
        other = try fixture.peer("bob", account: "b")
        replacement = try fixture.peer("alice", account: "a")
        for peer in [old, other, replacement] { peer.viewModel.allowsNearbyGroupDelivery = false }
        groupID = try fixture.completeGroupContactRegistration(from: other, to: old)
        for peer in [old, other, replacement] {
            peer.viewModel.disconnect()
            peer.viewModel.setRTCTransportRoutes([.multipeer])
        }
        let oldModel = old.viewModel, otherModel = other.viewModel
        trust = try #require(try replacement.viewModel.internetSettingsStore.identityTrust())
        oldSigner = try oldModel.internetSettingsStore.invitationSigner(memberID: "alice-old")
        backupOwner = .init(principal: try #require(oldSigner.principal), publicKey: oldSigner.publicKey)
        savedPersonID = try #require(oldModel.savedRemoteUsers.first?.id)
        let otherPerson = try #require(otherModel.savedRemoteUsers.first?.id)
        try #require(oldModel.selectUser(savedPersonID, connectIfIdle: false))
        try #require(otherModel.selectUser(otherPerson, connectIfIdle: false))
        directID = try #require(oldModel.selectedGroup?.id)
        try #require(otherModel.selectedGroup?.id == directID)
        let callIDs = [groupID, directID]
        var snapshot = GroupSnapshot()
        snapshot.groups = old.groupStore.snapshot.groups.filter { callIDs.contains($0.id) }
        snapshot.users = old.groupStore.snapshot.users
        try #require(snapshot.groups.count == callIDs.count)
        for record in snapshot.groups {
            let reference = try #require(record.credentialReference)
            let credential = try #require(try oldModel.groupRepository.credential(for: record.id))
            try restoredCredentials.saveSecret(credential.secret, reference: reference)
        }
        backup = snapshot
    }

    func openReboundSnapshot() throws -> AppTestSupport.Harness {
        let settings = replacement.viewModel.internetSettingsStore
        let newSigner = try settings.invitationSigner(memberID: "alice")
        try #require(backupOwner.publicKey != newSigner.publicKey)
        let store = InMemoryGroupStore()
        let destinationKeys = InMemoryGroupCredentialStore()
        let repository = GroupRepository(store: store, credentials: destinationKeys)
        _ = try repository.load(localMemberID: "alice")
        try repository.restoreCallRelationships(confirmedRestore(), as: newSigner, trust: trust)
        let harness = AppTestSupport.makeHarness(
            groups: [], groupStore: store, credentialStore: destinationKeys,
            internetSettingsStore: settings, localMemberID: "alice")
        harness.viewModel.allowsNearbyGroupDelivery = false
        harness.viewModel.setRTCTransportRoutes([.multipeer])
        return harness
    }

    func confirmedRestore(owner: AccountPrincipal? = nil) throws -> ConfirmedCallRestore {
        let model = other.viewModel
        let responder = try model.internetSettingsStore.invitationSigner(memberID: "bob")
        let requester = try replacement.viewModel.internetSettingsStore.invitationSigner(memberID: "alice")
        let principal = try #require(responder.principal)
        let recipient = AccountDeviceBinding(principal: principal, publicKey: responder.publicKey)
        let now = Date()
        let entries = try backup.groups.map { record in
            let reference = try #require(record.credentialReference)
            let secret = try #require(try restoredCredentials.secret(reference: reference))
            let request = try CallRelationshipRestoreRequest(callID: record.id, recipientMemberID: responder.memberID,
                                                              recipient: recipient, signer: requester, now: now)
            let confirmation = try #require(try model.groupRepository.confirmRestore(
                request, as: responder, trust: trust, now: now))
            return ConfirmedCallRestore.Call(record: record, credential: .init(groupID: record.id, secret: secret),
                                             request: request, confirmation: confirmation)
        }
        return .init(owner: owner ?? backupOwner.principal, previousMemberID: "alice-old",
                     users: backup.users, calls: entries)
    }
}
