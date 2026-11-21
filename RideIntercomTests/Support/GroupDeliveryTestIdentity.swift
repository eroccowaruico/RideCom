import CryptoKit
import Foundation
@testable import RideIntercom

@MainActor final class GroupDeliveryTestIdentity {
    let memberID: String
    let personID = UUID()
    let namespace = "RideIntercom.GroupDeliveryTests." + UUID().uuidString
    let keychain = DictionaryKeychain()
    let groupKeys = InMemoryGroupCredentialStore()
    private var memoryGroups: InMemoryGroupStore?
    private let groupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RideIntercom-GroupDelivery-" + UUID().uuidString)
    let store: InternetConnectionSettingsStore
    init(_ memberID: String) {
        self.memberID = memberID
        store = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
    }
    func authorizeFixture(
        userID: String, issuer: P256.Signing.PrivateKey = P256.Signing.PrivateKey(), relayEnabled: Bool = false
    ) throws {
        let deviceID = try store.accountDeviceID()
        let key = try store.deviceSigningKey()
        let hash = { (text: String) in SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        let secret = hash(deviceID)
        let now = Date()
        var claims: [String: Any] = ["sessionBinding": hash(hash(secret))]
        if relayEnabled {
            let period = Int(now.timeIntervalSince1970 / 2_592_000)
            let relay = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            claims["invitationRelayKey"] = [
                "kid": "v1-\(period)", "x": IdentityEncoding.encode(relay), "expiresAt": (period + 2) * 2_592_000
            ]
        }
        let certificate = try testIdentityCertificate(
            signer: issuer, userID: userID, deviceID: deviceID, memberID: memberID,
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), origin: "https://delivery.test",
            now: now,
            changes: claims)
        let identity = try certificate.verify(
            origin: URL(string: "https://delivery.test")!, trustedIssuerKey: certificate.issuerKey)
        try store.save(
            url: "https://delivery.test", token: "ri1." + userID + "." + deviceID + "." + secret,
            identity: identity)
    }
    var signer: DeviceIdentitySigner { get throws { try store.invitationSigner(memberID: memberID) } }
    var principal: AccountPrincipal { get throws {
        guard let value = try store.loadPrincipal(memberID: memberID) else { throw DeviceIdentityProof.Failure.invalid }
        return value
    } }
    func savedUser() throws -> SavedUser {
        .init(
            id: personID, displayName: memberID, memberIDs: [memberID],
            deviceKeys: [memberID: try signer.publicKey], principal: try principal)
    }
    func harness(knowing people: [GroupDeliveryTestIdentity], onDisk: Bool = false,
                 callAccessNow: @escaping @MainActor () -> Date = Date.init) throws -> AppTestSupport.Harness {
        if onDisk {
            let file = FileGroupStore(directory: groupDirectory)
            do {
                try file.lock(); defer { file.unlock() }
                if try file.read() == nil { try file.commit(GroupSnapshot(users: people.map { try $0.savedUser() })) }
            }
            return AppTestSupport.makeHarness(
                groups: [], groupRepository: GroupRepository(store: file, credentials: groupKeys),
                credentialStore: groupKeys, internetSettingsStore: store,
                invitationAuthority: testInvitationAuthority(keychain: keychain), localMemberID: memberID,
                callAccessNow: callAccessNow)
        }
        if memoryGroups == nil {
            let groups = InMemoryGroupStore(groups: [])
            groups.snapshot.users = try people.map { try $0.savedUser() }; memoryGroups = groups
        }
        return AppTestSupport.makeHarness(
            groups: [], groupStore: memoryGroups, credentialStore: groupKeys, internetSettingsStore: store,
            localMemberID: memberID, callAccessNow: callAccessNow)
    }
    func remove() {
        UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace)
        try? FileManager.default.removeItem(at: groupDirectory)
    }

}
