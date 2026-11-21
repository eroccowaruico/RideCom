import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupPersistenceTests {
    @Test func persistenceStoresIdentityWithoutRuntimeStateOrSecret() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try IntercomGroup(
            name: "Saved",
            members: [
                .init(
                    id: "local", displayName: "You", isMuted: true, isTalking: true, voiceLevel: 0.7,
                    receivedAudioPacketCount: 4, authenticationState: .authenticated, connectionState: .connected)
            ], accessSecret: "never-persist")
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "never-persist"))
        let text = try #require(String(bytes: Data(contentsOf: fixture.file.url), encoding: .utf8))
        #expect(!text.contains("never-persist"))
        #expect(!text.contains("voiceLevel"))
        #expect(!text.contains("isMuted"))
        let restored = try #require(try fixture.restart().load(localMemberID: "local").first)
        #expect(restored.members[0].connectionState == .offline)
        #expect(!restored.members[0].isTalking)
        #expect(!restored.members[0].isMuted)
    }

    @Test func corruptStoreIsReportedAndPreserved() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let data = Data("{broken".utf8)
        try data.write(to: fixture.file.url)
        #expect(throws: (any Error).self) { try fixture.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: fixture.file.url) == data)
    }

    @Test func groupCapacityAndIdentityAreValidated() throws {
        let members = (0..<8).map { GroupMember(id: "member-\($0)", displayName: "Rider") }
        #expect(try IntercomGroup(name: "Eight", members: members).members.count == 8)
        #expect(throws: (any Error).self) {
            try IntercomGroup(name: "Nine", members: members + [.init(id: "ninth", displayName: "Rider")])
        }
        #expect(throws: (any Error).self) { try IntercomGroup(name: "Duplicate", members: [members[0], members[0]]) }
        #expect(throws: (any Error).self) {
            try IntercomGroup(name: "Empty ID", members: [.init(id: "", displayName: "Rider")])
        }
    }

    @Test func decodedInviteRejectsUnsupportedVersionAndOversizedURL() throws {
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("remote"), groupID: UUID(),
            groupName: "Group", groupSecret: "shared", inviterMemberID: "remote")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        json["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://join?token=\(encoded)"))
        #expect(throws: GroupInviteTokenError.unsupportedVersion) { try GroupInviteTokenCodec.decodeJoinURL(url) }
        let huge = try #require(URL(string: "rideintercom://join?token=" + String(repeating: "a", count: 20000)))
        #expect(throws: GroupInviteTokenError.invalidURL) { try GroupInviteTokenCodec.decodeJoinURL(huge) }
    }

    @Test func failedReadBlocksWritesAndDoesNotCreateKeys() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let corrupted = Data("invalid".utf8)
        try corrupted.write(to: fixture.file.url)
        let repository = fixture.restart()
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        let group = try fixture.group()
        #expect(throws: (any Error).self) {
            try repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        }
        #expect(try Data(contentsOf: fixture.file.url) == corrupted)
        #expect(fixture.keys.references().isEmpty)
    }

    @Test func decodedStoredGroupsStillValidateIdentityAndRestoreLocalFirst() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try IntercomGroup(
            name: "Order",
            members: [.init(id: "remote", displayName: "Rider"), .init(id: "local", displayName: "You")])
        try fixture.repository.save([group])
        #expect(try fixture.restart().load(localMemberID: "local")[0].members[0].id == "local")
        var snapshot = try #require(try fixture.file.read())
        snapshot.groups[0].members = [.init(id: "local", displayName: "A"), .init(id: "local", displayName: "B")]
        try JSONEncoder().encode(snapshot).write(to: fixture.file.url)
        #expect(throws: (any Error).self) { try fixture.restart().load(localMemberID: "local") }
    }
}
