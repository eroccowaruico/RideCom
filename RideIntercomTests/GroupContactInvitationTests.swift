import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupContactInvitationTests {
    @Test func anUnsignedGroupAttachmentCannotBeAddedToAContactInvitation() throws {
        let token = try ContactInvitationSession.makeToken(authority: testInvitationAuthority(), signer: testIdentitySigner("group-author"),
            displayName: "Author", now: Date().timeIntervalSince1970)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        fields["invitedGroup"] = ["id": UUID().uuidString, "name": "Forged group", "secret": "forged-secret"]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://contact?token=" + encoded))
        #expect(throws: (any Error).self) { try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true) }
    }
    @Test func aCombinedInvitationBindsTheGroupWithoutPuttingItsKeyInTheReceipt() throws {
        let author = testIdentitySigner("group-author"), recipient = testIdentitySigner("group-recipient")
        let authority = testInvitationAuthority(), now = Date().timeIntervalSince1970
        let group = ContactGroupInvitation(id: UUID(), name: "Mountain riders", secret: "group-only-key")
        let token = try ContactInvitationSession.makeToken(authority: authority, signer: author, displayName: "Author", now: now, invitedGroup: group)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        #expect(decoded.invitedGroup == group)
        #expect(decoded.groupID != group.id && decoded.groupSecret != group.secret)
        let accepted = try decoded.accept(signer: recipient, displayName: "Recipient", now: now, contactBootstrap: true)
        #expect(try authority.verify(accepted.receipt, now: now) != nil)
        #expect(accepted.receipt.invitation?.invitedGroupID == group.id)
        #expect(accepted.receipt.invitation?.invitedGroupDigest == (try group.digest()))
        #expect(!String(decoding: try JSONEncoder().encode(accepted.receipt), as: UTF8.self).contains(group.secret))
        var changed = accepted.receipt
        changed.invitation?.invitedGroupID = UUID()
        #expect(try authority.verify(changed, now: now) == nil)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        fields["invitedGroup"] = ["id": group.id.uuidString, "name": group.name, "secret": "replaced-key"]
        let tampered = try JSONDecoder().decode(GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try tampered.validate(contactBootstrap: true) }
        #expect(!tampered.verifySignature())
    }

}
