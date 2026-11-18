import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor struct GroupInvitationEnvelopeTests {
    private let sender = AccountPrincipal(issuer: "https://worker.test", userID: String(repeating: "a", count: 64))
    private let receiver = AccountPrincipal(issuer: "https://worker.test", userID: String(repeating: "b", count: 64))
    private func fixture() throws -> (GroupInviteToken, DeviceIdentitySigner, DeviceIdentitySigner, SavedUser) {
        let a = testIdentitySigner("envelope-author"), b = testIdentitySigner("envelope-recipient")
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a, groupID: UUID(), groupName: "Private mountain group",
            groupSecret: "private-group-key-not-for-the-server", inviterMemberID: a.memberID)
        return (token, a, b, .init(displayName: "Author", memberIDs: [a.memberID], deviceKeys: [a.memberID: a.publicKey], principal: sender))
    }
    @Test func onlyTheAddressedDeviceCanReadTheSignedGroupWithoutExposingItsKeyToTheRouter() throws {
        let (token, a, b, user) = try fixture()
        let value = try GroupInvitationEnvelope.seal(token, sender: sender, recipient: receiver, recipientMemberID: b.memberID, recipientKey: b.publicKey, signer: a)
        let encoded = try JSONEncoder().encode(value)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(token.groupSecret))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(token.groupName))
        let decoded = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: encoded)
        let opened = try decoded.open(recipient: b, local: receiver, sender: user)
        #expect(opened.groupID == token.groupID && opened.groupSecret == token.groupSecret && opened.verifySignature())
        #expect(throws: (any Error).self) { try value.open(recipient: testIdentitySigner("other-device"), local: receiver, sender: user) }
    }
    @Test func aSmallClockDifferenceDoesNotRejectAValidWeekLongInvitation() throws {
        let now = Date(), a = testIdentitySigner("clock-author"), b = testIdentitySigner("clock-recipient")
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a, groupID: UUID(), groupName: "Clock group",
            groupSecret: "synthetic-clock-key", inviterMemberID: a.memberID, issuedAt: now.timeIntervalSince1970, expiresAt: now.addingTimeInterval(7 * 86400).timeIntervalSince1970)
        let envelope = try GroupInvitationEnvelope.seal(token, sender: sender, recipient: receiver, recipientMemberID: b.memberID, recipientKey: b.publicKey, signer: a, now: now)
        let user = SavedUser(displayName: "Author", memberIDs: [a.memberID], deviceKeys: [a.memberID: a.publicKey], principal: sender)
        let opened = try envelope.open(recipient: b, local: receiver, sender: user, now: now.addingTimeInterval(-60))
        #expect(opened.groupID == token.groupID)
        #expect(throws: (any Error).self) { try envelope.open(recipient: b, local: receiver, sender: user, now: now.addingTimeInterval(-600)) }
    }

    @Test func changedRoutingOrCiphertextAndUnknownSendersAreRejected() throws {
        let (token, a, b, user) = try fixture()
        let value = try GroupInvitationEnvelope.seal(token, sender: sender, recipient: receiver, recipientMemberID: b.memberID, recipientKey: b.publicKey, signer: a)
        var changed = value; changed.id = UUID()
        #expect(throws: (any Error).self) { try changed.open(recipient: b, local: receiver, sender: user) }
        changed = value; changed.ciphertext[0] ^= 1
        #expect(throws: (any Error).self) { try changed.open(recipient: b, local: receiver, sender: user) }
        changed = value; changed.recipient = sender
        #expect(throws: (any Error).self) { try changed.open(recipient: b, local: receiver, sender: user) }
        var stranger = user; stranger.deviceKeys = [a.memberID: testIdentitySigner("stranger").publicKey]
        #expect(throws: (any Error).self) { try value.open(recipient: b, local: receiver, sender: stranger) }
        #expect(throws: (any Error).self) { try value.open(recipient: b, local: receiver, sender: user, now: Date().addingTimeInterval(8 * 86400)) }
    }
}
