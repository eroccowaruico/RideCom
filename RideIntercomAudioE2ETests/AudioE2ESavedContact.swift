import CryptoKit
import Foundation
import RTC
import XCTest
@testable import RideIntercom

@MainActor
enum AudioE2ESavedContact {
    static func store(for run: AudioE2ENetworkRun, in repository: GroupRepository,
                      keychain: FixtureKeychain, namespace: String) throws {
        let local = try fixtureKey(run: run.identifier, memberID: run.memberID)
        let remote = try fixtureKey(run: run.identifier, memberID: run.otherMemberID)
        keychain.saveSecret(local.rawRepresentation.base64EncodedString(),
                            service: namespace + ".InternetConnection", account: "identity-key")
        _ = try repository.load(localMemberID: run.memberID)
        let group = try IntercomGroup(id: run.groupID, name: "Direct Call", members: [
            .init(id: run.memberID, displayName: "Audio E2E \(run.role)"),
            .init(id: run.otherMemberID, displayName: "Audio E2E peer")
        ], kind: .direct)
        let remotePublicKey = IdentityEncoding.encode(remote.publicKey.x963Representation)
        let contact = SavedUser(displayName: "Audio E2E peer", memberIDs: [run.otherMemberID],
                                deviceKeys: [run.otherMemberID: remotePublicKey])
        try repository.update([group], credential: .init(groupID: group.id, secret: run.groupSecret), users: [contact])
    }

    static func start(for run: AudioE2ENetworkRun, in viewModel: IntercomViewModel) throws {
        XCTAssertEqual(viewModel.enabledRTCTransportRoutes, [.multipeer, .webRTC])
        XCTAssertEqual(viewModel.hasInternetCredentials, !run.delaysInternetRegistration)
        if !run.delaysInternetRegistration { viewModel.setRTCTransportRoute(.multipeer, enabled: false) }
        let contact = try XCTUnwrap(viewModel.savedRemoteUsers.first { $0.memberIDs == [run.otherMemberID] })
        XCTAssertEqual(viewModel.existingDirectCall(for: contact.id)?.id, run.groupID)
        XCTAssertNil(viewModel.activeGroupID)
        viewModel.openDestination(.user(contact.id))
        XCTAssertEqual(viewModel.activeGroupID, run.groupID)
    }

    // Both test processes derive fixture keys from their shared run identifier.
    private static func fixtureKey(run: String, memberID: String) throws -> P256.Signing.PrivateKey {
        var scalar = Data(SHA256.hash(data: Data("audio-e2e-fixture:\(run):\(memberID)".utf8)))
        scalar[0] &= 0x7f
        scalar[31] |= 1
        return try P256.Signing.PrivateKey(rawRepresentation: scalar)
    }
}
