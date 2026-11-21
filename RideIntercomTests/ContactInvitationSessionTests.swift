import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationSessionTests {
    /// Exercise Bonjour discovery, QUIC authentication and signed acceptance through the standalone data route.
    @Test(.timeLimit(.minutes(1)))
    func nativeControlOnlyReceivesAcceptanceFromPreviouslyUnknownPeer() async throws {
        let suffix = UUID().uuidString.prefix(8)
        let authorID = "contact-author-\(suffix)"
        let friendID = "contact-friend-\(suffix)"
        let authorSigner = testIdentitySigner(authorID), friendSigner = testIdentitySigner(friendID)
        var authorsContacts: [String] = []
        var friendsContacts: [String] = []
        let author = ContactInvitationSession(authority: testInvitationAuthority(),
            signer: authorSigner, displayName: "Author", routes: [.multipeer]) { identity, name in
                #expect(identity.memberID == friendID)
                #expect(name == "Friend")
                authorsContacts.append(identity.memberID)
            }
        let friend = ContactInvitationSession(authority: testInvitationAuthority(),
            signer: friendSigner, displayName: "Friend", routes: [.multipeer]) { identity, name in
                #expect(identity.memberID == authorID)
                #expect(name == "Author")
                friendsContacts.append(identity.memberID)
            }
        defer { author.stop(); friend.stop() }
        let url = try author.issue()
        #expect(authorsContacts.isEmpty)
        try friend.accept(url)
        #expect(friendsContacts == [authorID], "Explicit acceptance stores the signed inviter immediately")
        let deadline = ContinuousClock.now + .seconds(30)
        while !author.isConfirmed || !friend.isAcknowledged, ContinuousClock.now < deadline {
            friend.retry()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(authorsContacts == [friendID])
        #expect(friendsContacts == [authorID])
        #expect(author.isConfirmed)
        #expect(friend.isAcknowledged)
        try await verifyGroupPermission(author: author, friend: friend, authorID: authorID, authorSigner: authorSigner)
    }

    private func verifyGroupPermission(
        author: ContactInvitationSession, friend: ContactInvitationSession, authorID: String,
        authorSigner: DeviceIdentitySigner
    ) async throws {
        let source = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
        let destination = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))
        let grant = try testCallNotificationGrant(
            owner: source, allowedSender: destination, audience: "rideintercom-group-invitation")
        let permission = try CallNotificationPermissionMessage.make(
            owner: source, allowedSender: destination, revision: 1,
            grant: nil, signer: authorSigner, groupGrant: grant, groupInvitationsSupported: true)
        let savedAuthor = SavedUser(
            displayName: "Author", memberIDs: [authorID], deviceKeys: [authorID: authorSigner.publicKey],
            principal: source)
        var receivedGroupPermission = false
        friend.onNotificationPermission = { peerID, message in
            guard message.namespace == CallNotificationPermissionMessage.groupNamespace,
                let value = try? JSONDecoder().decode(
                    CallNotificationPermissionMessage.self, from: message.payload)
            else { return }
            do {
                _ = try value.verifiedGrant(peerID: peerID, savedUser: savedAuthor, local: destination)
                receivedGroupPermission = value.groupGrant == grant
            } catch { Issue.record("The group permission must verify against the registered device") }
        }
        #expect(
            author.sendNotificationPermission(
                try JSONEncoder().encode(permission), namespace: CallNotificationPermissionMessage.groupNamespace))
        let permissionDeadline = ContinuousClock.now + .seconds(5)
        while !receivedGroupPermission, ContinuousClock.now < permissionDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(receivedGroupPermission, "The separate group permission crosses the real QUIC exchange")
    }
}
