import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct DirectInvitationAuthorityTests {
    @Test func internetReplyPacketBindsTheDeviceInvitationReceiptAndDirection() throws {
        let authority = testInvitationAuthority()
        let author = testIdentitySigner("reply-author"), recipient = testIdentitySigner("reply-recipient")
        let observer = testIdentitySigner("group-observer")
        let group = UUID(), expiresAt = 2_000.125
        let credential = GroupAccessCredential(groupID: group, secret: "ordinary-internet-packet-test")
        let grant = try authority.issue(.init(groupID: group, inviterMemberID: author.memberID,
                                              inviterDeviceKey: author.publicKey, expiresAt: expiresAt))
        let address = try InvitationReplyAddress(invitation: grant.context, credential: credential)
        #expect(address.expiresAt == 2_000_125)
        #expect(address.slot.utf8.count == 64)
        var anotherInvite = grant.context; anotherInvite.id = UUID()
        let otherAddress = try InvitationReplyAddress(invitation: anotherInvite, credential: credential)
        let different = address.slot != otherAddress.slot
        #expect(different)
        let accepted = try DirectInvitationReceipt.make(grant: grant, signer: recipient,
                                                         inviteeMemberID: recipient.memberID, displayName: "Recipient")
        let sent = try InvitationReplyPacket.seal(accepted, address: address, invitation: grant.context, now: 1_000)
        let received = try sent.open(
            address: address, invitation: grant.context, kind: .accepted, signer: author, now: 1_000)
        let matches = received == accepted
        #expect(matches)
        #expect(try authority.verify(received, now: 1_000) != nil)
        #expect(throws: (any Error).self) {
            try sent.open(address: address, invitation: grant.context, kind: .accepted, signer: observer, now: 1_000)
        }
        #expect(throws: (any Error).self) {
            try sent.open(address: otherAddress, invitation: grant.context, kind: .accepted, signer: author, now: 1_000)
        }
        #expect(throws: (any Error).self) {
            try sent.open(address: address, invitation: grant.context, kind: .acknowledged, signer: author, now: 1_000)
        }
        let newID = InvitationReplyPacket(id: UUID(), packet: sent.packet)
        #expect(throws: (any Error).self) {
            try newID.open(address: address, invitation: grant.context, kind: .accepted, signer: author, now: 1_000)
        }
        var altered = try #require(Data(base64Encoded: sent.packet))
        altered[altered.index(before: altered.endIndex)] ^= 1
        let tampered = InvitationReplyPacket(id: sent.id, packet: altered.base64EncodedString())
        #expect(throws: (any Error).self) {
            try tampered.open(address: address, invitation: grant.context, kind: .accepted, signer: author, now: 1_000)
        }
        #expect(throws: (any Error).self) {
            try sent.open(address: address, invitation: grant.context, kind: .accepted, signer: author, now: expiresAt)
        }

        let acknowledgement = try received.acknowledged(by: author)
        let reply = try InvitationReplyPacket.seal(
            acknowledgement, address: address, invitation: grant.context, now: 1_000)
        let opened = try reply.open(
            address: address, invitation: grant.context, kind: .acknowledged, signer: recipient, now: 1_000)
        try opened.verifyAcknowledgement(of: accepted, trust: nil, now: 1_000)
    }

    @Test func receiptCannotBeReassignedOrExtendedByAGroupObserver() throws {
        let authority = testInvitationAuthority()
        let grant = try authority.issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        let original = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        #expect(try authority.verify(original, now: 199.99) != nil)
        #expect(try authority.verify(original, now: 200) == nil)
        #expect(try authority.verify(original, now: .nan) == nil)
        var mutations: [DirectInvitationReceipt] = []
        var changed = original; changed.id = UUID(); mutations.append(changed)
        changed = original; changed.inviteeMemberID = "stranger"; mutations.append(changed)
        changed = original; changed.invitation?.expiresAt = 300; mutations.append(changed)
        changed = original; changed.invitation?.id = UUID(); mutations.append(changed)
        changed = original; changed.groupID = UUID(); changed.invitation?.groupID = changed.groupID
        mutations.append(changed)
        changed = original; changed.inviterMemberID = "other-author"
        changed.invitation?.inviterMemberID = "other-author"; mutations.append(changed)
        changed = original; changed.proof = nil; mutations.append(changed)
        for receipt in mutations { #expect(try authority.verify(receipt, now: 100) == nil) }
        changed = original; changed.displayName = "New shared name"
        #expect(try authority.verify(changed, now: 100) == nil)
    }

    @Test func groupObserverCannotSubstituteItsOwnKeyOnAValidReceipt() throws {
        let authority = testInvitationAuthority()
        let grant = try authority.issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        var observed = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        let impostor = try DeviceIdentitySigner(memberID: "friend", key: P256.Signing.PrivateKey())
        observed.acceptanceProof = try impostor.sign(observed.identityMessage(), purpose: .acceptInvitation)
        #expect(try authority.verify(observed, now: 100) == nil)
        observed.inviteeDeviceKey = impostor.publicKey
        observed.acceptanceProof = try impostor.sign(observed.identityMessage(), purpose: .acceptInvitation)
        // Changing the key also invalidates the invitation HMAC.
        #expect(try authority.verify(observed, now: 100) == nil)

    }

    @Test func reopeningTheSameInvitationHasTheSameReceiptIdentity() throws {
        let authority = testInvitationAuthority()
        let grant = try authority.issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        let first = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        let reopened = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Renamed")
        #expect(first.id == reopened.id)
        #expect(first.proof == reopened.proof)
        let other = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("other"), inviteeMemberID: "other", displayName: "Other")
        #expect(first.id != other.id)
        let freshGrant = try authority.issue(
            .init(
                groupID: grant.context.groupID, inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        let fresh = try DirectInvitationReceipt.make(
            grant: freshGrant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend",
            displayName: "Friend")
        #expect(first.id != fresh.id)
        var invented = first; invented.id = UUID()
        invented.proof = Data(HMAC<SHA256>.authenticationCode(for: try invented.proofMessage(),
            using: SymmetricKey(data: try #require(Data(base64Encoded: grant.secret))))).base64EncodedString()
        // Even a link holder cannot choose a new replay identity.
        #expect(try authority.verify(invented, now: 100) == nil)
    }

    @Test func privateAuthorKeySurvivesRestartAndIsNotReplacedWhenUnreadable() throws {
        let keychain = AccountTestKeychain()
        let authority = testInvitationAuthority(keychain: keychain)
        let grant = try authority.issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        let retained = try #require(keychain.value)
        let restarted = testInvitationAuthority(keychain: keychain)
        #expect(try restarted.verify(receipt, now: 100) != nil)
        #expect(try testInvitationAuthority().verify(receipt, now: 100) == nil)
        keychain.fails = true
        #expect(throws: (any Error).self) { try restarted.issue(grant.context) }
        #expect(throws: (any Error).self) { try restarted.verify(receipt, now: 100) }
        #expect(keychain.value == retained)
        keychain.fails = false; keychain.value = "invalid retained key"
        #expect(throws: (any Error).self) { try restarted.issue(grant.context) }
        #expect(keychain.value == "invalid retained key")
    }

    @Test func accountNamespacesAndKeyRemovalDoNotCarryOldInvitationsAcrossAccounts() throws {
        let keychain = DictionaryKeychain()
        let firstAuthority = DirectInvitationAuthority(keychain: keychain, namespace: "account-a")
        let secondAuthority = DirectInvitationAuthority(keychain: keychain, namespace: "account-b")
        let context = DirectInvitationContext(
            groupID: UUID(), inviterMemberID: "author", inviterDeviceKey: testIdentitySigner("author").publicKey,
            expiresAt: 200)
        let grant = try firstAuthority.issue(context)
        let receipt = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        _ = try secondAuthority.issue(context)
        #expect(try secondAuthority.verify(receipt, now: 100) == nil)
        #expect(try firstAuthority.verify(receipt, now: 100) != nil)
        try keychain.deleteSecret(service: "account-a.DirectInvitations", account: "author")
        _ = try firstAuthority.issue(context)
        #expect(try firstAuthority.verify(receipt, now: 100) == nil)
        #expect(try keychain.secret(service: "account-b.DirectInvitations", account: "author") != nil)
    }

    @Test func concurrentFirstIssuanceAdoptsTheKeyInstalledByAnotherProcess() throws {
        let keychain = InvitationKeyRace()
        let authority = testInvitationAuthority(keychain: keychain)
        let grant = try authority.issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey, expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        #expect(try authority.verify(receipt, now: 100) != nil)
        #expect(!keychain.overwroteWinner)
    }

    @Test func verificationDoesNotCreateAuthorKeysAndDirectedGrantRejectsOtherRecipients() throws {
        let keychain = InternetTestKeychain()
        let unknownAuthor = testInvitationAuthority(keychain: keychain)
        let grant = try testInvitationAuthority().issue(
            .init(
                groupID: UUID(), inviterMemberID: "author",
                inviterDeviceKey: testIdentitySigner("author").publicKey,
                                                             recipientMemberID: "friend", expiresAt: 200))
        let receipt = try DirectInvitationReceipt.make(
            grant: grant, signer: testIdentitySigner("friend"), inviteeMemberID: "friend", displayName: "Friend")
        #expect(try unknownAuthor.verify(receipt, now: 100) == nil)
        #expect(keychain.value == nil)
        #expect(throws: GroupInviteTokenError.invalidTokenEncoding) {
            try DirectInvitationReceipt.make(
                grant: grant, signer: testIdentitySigner("stranger"), inviteeMemberID: "stranger",
                displayName: "Stranger")
        }
    }

    @Test func invitationURLReceiptsSaveOnlyTheDirectPairAndNeverPublishTheCapability() throws {
        let group = try IntercomGroup(
            name: "Friends", members: [.init(id: "author", displayName: "Author")], accessSecret: "group-secret")
        let author = AppTestSupport.makeHarness(groups: [group])
        let friend = AppTestSupport.makeHarness(groups: [])
        let authorModel = author.viewModel; let recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        authorModel.selectGroup(group)
        let url = try #require(authorModel.makeSelectedGroupInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url)
        let grant = try #require(token.directInvitation)
        try recipientModel.acceptInviteURL(url)
        #expect(recipientModel.savedUsers.map(\.memberIDs) == [["author"]])
        friend.callSession.authenticate(["author", "stranger"])
        let sent = try #require(
            friend.callSession.sentApplicationDataMessages.last {
                $0.namespace == DirectInvitationReceipt.namespace
            })
        let body = try #require(String(data: sent.payload, encoding: .utf8))
        #expect(!body.contains(grant.secret))
        let snapshot = try friend.groupStore.snapshot.encoded()
        let savedDocument = try #require(String(data: snapshot, encoding: .utf8))
        #expect(!savedDocument.contains(grant.secret))
        author.callSession.authenticate([recipientModel.localMemberIdentity.memberID, "stranger"])
        var invalidName = try JSONDecoder().decode(DirectInvitationReceipt.self, from: sent.payload)
        invalidName.displayName = "Forged name"
        authorModel.handleTransportEvent(.receivedApplicationData(peerID: recipientModel.localMemberIdentity.memberID,
                message: .init(
                    namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(invalidName))))
        #expect(authorModel.groupStorageIssue == nil) // A bad peer signature cannot disable editing.
        #expect(authorModel.savedUsers.isEmpty)
        authorModel.handleTransportEvent(
            .receivedApplicationData(peerID: recipientModel.localMemberIdentity.memberID, message: sent))
        #expect(authorModel.savedUsers.map(\.memberIDs) == [[recipientModel.localMemberIdentity.memberID]])
        let acknowledgement = try #require(
            author.callSession.sentApplicationDataMessages.last {
                $0.namespace == DirectInvitationReceipt.namespace
            })
        var invalidACK = try JSONDecoder().decode(DirectInvitationReceipt.self, from: acknowledgement.payload)
        invalidACK.displayName = "Forged acknowledgement"
        recipientModel.handleTransportEvent(.receivedApplicationData(peerID: "author",
                message: .init(
                    namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(invalidACK))))
        #expect(recipientModel.groupStorageIssue == nil)
        #expect(recipientModel.groupRepository.pendingInvitation(for: group.id) != nil)
        recipientModel.handleTransportEvent(.receivedApplicationData(peerID: "author", message: acknowledgement))
        #expect(recipientModel.groupRepository.pendingInvitation(for: group.id) == nil)
        #expect(!authorModel.savedUsers.flatMap(\.memberIDs).contains("stranger"))
        #expect(!recipientModel.savedUsers.flatMap(\.memberIDs).contains("stranger"))
        #expect(recipientModel.removeSavedUser(try #require(recipientModel.savedUsers.first).id))
        #expect(authorModel.removeSavedUser(try #require(authorModel.savedUsers.first).id))
        authorModel.handleTransportEvent(
            .receivedApplicationData(peerID: recipientModel.localMemberIdentity.memberID, message: sent))
        #expect(authorModel.savedUsers.isEmpty)
        try recipientModel.acceptInviteURL(url) // Reopening an old link still cannot restore either deleted entry.
        #expect(recipientModel.savedUsers.isEmpty)
        recipientModel.sendPendingInvitationReceipt()
        let reopened = try #require(
            friend.callSession.sentApplicationDataMessages.last {
                $0.namespace == DirectInvitationReceipt.namespace
            })
        authorModel.handleTransportEvent(
            .receivedApplicationData(peerID: recipientModel.localMemberIdentity.memberID, message: reopened))
        #expect(authorModel.savedUsers.isEmpty)
        var forged = try JSONDecoder().decode(DirectInvitationReceipt.self, from: sent.payload)
        forged.inviteeMemberID = "stranger"; forged.id = UUID()
        let message = ApplicationDataMessage(
            namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(forged))
        authorModel.handleTransportEvent(.receivedApplicationData(peerID: "stranger", message: message))
        #expect(authorModel.savedUsers.isEmpty)
    }
}

@MainActor
private final class InvitationKeyRace: KeychainSecretStoring {
    private var firstRead = true
    private let winner = Data(repeating: 7, count: 32).base64EncodedString()
    private(set) var overwroteWinner = false
    func accounts(service: String) throws -> [String] { ["author"] }
    func secret(service: String, account: String) throws -> String? {
        if firstRead { firstRead = false; return nil }
        return winner
    }
    func createSecretIfAbsent(_ secret: String, service: String, account: String) throws -> String { winner }
    func saveSecret(_ secret: String, service: String, account: String) throws { overwroteWinner = true }
    func deleteSecret(service: String, account: String) throws { }
}
