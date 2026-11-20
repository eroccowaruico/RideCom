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
    private let groupDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RideIntercom-GroupDelivery-" + UUID().uuidString)
    let store: InternetConnectionSettingsStore
    init(_ memberID: String) {
        self.memberID = memberID
        store = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
    }
    func authorizeFixture(userID: String, issuer: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws {
        let deviceID = try store.accountDeviceID()
        let key = try store.deviceSigningKey()
        let certificate = try testIdentityCertificate(signer: issuer, userID: userID, deviceID: deviceID, memberID: memberID,
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), origin: "https://delivery.test")
        let identity = try certificate.verify(origin: URL(string: "https://delivery.test")!, trustedIssuerKey: certificate.issuerKey)
        try store.save(url: "https://delivery.test", token: "ri1." + userID + "." + deviceID + "." + String(repeating: "f", count: 64), identity: identity)
    }
    var signer: DeviceIdentitySigner { get throws { try store.invitationSigner(memberID: memberID) } }
    var principal: AccountPrincipal { get throws {
        guard let value = try store.loadPrincipal(memberID: memberID) else { throw DeviceIdentityProof.Failure.invalid }
        return value
    } }
    func savedUser() throws -> SavedUser {
        .init(id: personID, displayName: memberID, memberIDs: [memberID], deviceKeys: [memberID: try signer.publicKey], principal: try principal)
    }
    func harness(knowing people: [GroupDeliveryTestIdentity], onDisk: Bool = false) throws -> AppTestSupport.Harness {
        if onDisk {
            let file = FileGroupStore(directory: groupDirectory)
            do {
                try file.lock(); defer { file.unlock() }
                if try file.read() == nil { try file.commit(GroupSnapshot(users: people.map { try $0.savedUser() })) }
            }
            return AppTestSupport.makeHarness(groups: [], groupRepository: GroupRepository(store: file, credentials: groupKeys),
                credentialStore: groupKeys, internetSettingsStore: store, localMemberID: memberID)
        }
        if memoryGroups == nil {
            let groups = InMemoryGroupStore(groups: []); groups.snapshot.users = try people.map { try $0.savedUser() }; memoryGroups = groups
        }
        return AppTestSupport.makeHarness(groups: [], groupStore: memoryGroups, credentialStore: groupKeys, internetSettingsStore: store, localMemberID: memberID)
    }
    func remove() {
        UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace)
        try? FileManager.default.removeItem(at: groupDirectory)
    }

}
