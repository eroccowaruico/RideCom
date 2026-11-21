import Foundation

final class KeychainGroupCredentialStore: GroupCredentialStoring {
    private let service: String
    private let keychain: KeychainSecretStoring
    init(keychain: KeychainSecretStoring = SystemKeychainSecretStore(), namespace: String = "RideIntercom") {
        self.keychain = keychain; self.service = namespace + ".GroupCredential.v2"
    }
    func saveSecret(_ secret: String, reference: UUID) throws {
        guard try keychain.secret(service: service, account: reference.uuidString) == nil else {
            throw GroupStorageError.verificationFailed
        }
        try keychain.saveSecret(secret, service: service, account: reference.uuidString)
    }
    func secret(reference: UUID) throws -> String? {
        try keychain.secret(service: service, account: reference.uuidString)
    }
    func delete(reference: UUID) throws { try keychain.deleteSecret(service: service, account: reference.uuidString) }
    func references() throws -> Set<UUID> {
        Set(try keychain.accounts(service: service).compactMap(UUID.init(uuidString:)))
    }
}
