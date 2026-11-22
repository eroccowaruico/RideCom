import CryptoKit
import Foundation

/// Keeps the device's scoped cloud backup and restoration progress.
struct CallRelationshipBackupCheckpointStore {
    enum Environment: String, Encodable { case development, production }

    struct CloudAccount: Encodable, Equatable {
        let container: String
        let environment: Environment
        let account: String
    }

    struct Checkpoint: Codable, Equatable {
        let saved: String?
        let pending: String?

        func matches(_ remote: String?) -> Bool {
            remote == saved || (remote != nil && remote == pending)
        }

        var isValid: Bool {
            let fingerprints = [saved, pending].compactMap { $0 }
            return !fingerprints.isEmpty && fingerprints.allSatisfy(CallRelationshipBackupCheckpointStore.isFingerprint)
        }
    }

    struct RestoreSelection: Codable, Equatable {
        var id = UUID()
        let contactID: UUID
        let fingerprint: String

        func matches(_ candidate: CallRelationshipBackup.Contact) throws -> Bool {
            guard contactID == candidate.id else { return false }
            return try CallRelationshipBackupCheckpointStore.fingerprint(candidate) == fingerprint
        }
    }

    struct RestoreProgress: Codable, Equatable {
        let selection: RestoreSelection
        var draft: DirectRestoreRequestDraft?
    }

    private struct Scope: Encodable {
        let cloud: CloudAccount
        let owner: AccountPrincipal
        let deviceKey: String
    }

    static let serviceSuffix = ".CallRelationshipBackupCheckpoint.v1"
    private static let maximumRestoreBytes = 48 * 1_024
    private let keychain: KeychainSecretStoring
    private let service: String
    let cloud: CloudAccount

    init(keychain: KeychainSecretStoring, namespace: String, cloud: CloudAccount) {
        self.keychain = keychain
        service = namespace + Self.serviceSuffix
        self.cloud = cloud
    }

    func load(as signer: DeviceIdentitySigner) throws -> Checkpoint? {
        guard let stored = try keychain.secret(service: service, account: account(as: signer)) else { return nil }
        let value = try JSONDecoder().decode(Checkpoint.self, from: Data(stored.utf8))
        guard value.isValid else { throw KeychainSecretStoreError.invalidData }
        return value
    }

    func save(_ value: Checkpoint, as signer: DeviceIdentitySigner) throws {
        guard value.isValid, let encoded = String(data: try JSONEncoder().encode(value), encoding: .utf8) else {
            throw KeychainSecretStoreError.invalidData
        }
        try keychain.saveSecret(encoded, service: service, account: account(as: signer))
        guard try load(as: signer) == value else { throw KeychainSecretStoreError.invalidData }
    }

    func loadRestoreSelection(as signer: DeviceIdentitySigner) throws -> RestoreSelection? {
        try loadRestoreProgress(as: signer)?.selection
    }

    func loadRestoreProgress(as signer: DeviceIdentitySigner) throws -> RestoreProgress? {
        let key = try account(as: signer) + ".restore-selection"
        guard let value: RestoreProgress = try loadRestoreValue(key) else { return nil }
        guard Self.isFingerprint(value.selection.fingerprint) else { throw KeychainSecretStoreError.invalidData }
        return value
    }

    func saveRestoreSelection(_ value: RestoreSelection?, as signer: DeviceIdentitySigner) throws {
        try saveRestoreProgress(value.map { RestoreProgress(selection: $0) }, as: signer)
    }

    func saveRestoreProgress(_ value: RestoreProgress?, as signer: DeviceIdentitySigner) throws {
        if let value, !Self.isFingerprint(value.selection.fingerprint) { throw KeychainSecretStoreError.invalidData }
        try saveRestoreValue(value, key: account(as: signer) + ".restore-selection")
    }

    func loadRestoreReply(for requestID: String, as signer: DeviceIdentitySigner) throws
        -> DirectRestoreResponseDraft? {
        try loadRestoreValue(restoreReplyKey(for: requestID, as: signer))
    }

    func saveRestoreReply(_ value: DirectRestoreResponseDraft?, for requestID: String,
                          as signer: DeviceIdentitySigner) throws {
        try saveRestoreValue(value, key: restoreReplyKey(for: requestID, as: signer))
    }

    func pruneRestoreReplies(keeping requestIDs: Set<String>, as signer: DeviceIdentitySigner) throws {
        let prefix = try account(as: signer) + ".restore-reply."
        let retained = Set(requestIDs.map { prefix + $0 })
        for key in try keychain.accounts(service: service) where key.hasPrefix(prefix) && !retained.contains(key) {
            try keychain.deleteSecret(service: service, account: key)
        }
    }

    private func restoreReplyKey(for requestID: String, as signer: DeviceIdentitySigner) throws -> String {
        guard UUID(uuidString: requestID)?.uuidString.lowercased() == requestID
        else { throw KeychainSecretStoreError.invalidData }
        return try account(as: signer) + ".restore-reply." + requestID
    }

    private func loadRestoreValue<T: Decodable>(_ key: String) throws -> T? {
        guard let stored = try keychain.secret(service: service, account: key) else { return nil }
        guard stored.utf8.count <= Self.maximumRestoreBytes else { throw KeychainSecretStoreError.invalidData }
        return try JSONDecoder().decode(T.self, from: Data(stored.utf8))
    }

    private func saveRestoreValue<T: Codable & Equatable>(_ value: T?, key: String) throws {
        if let value {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            guard let encoded = String(bytes: try encoder.encode(value), encoding: .utf8),
                  encoded.utf8.count <= Self.maximumRestoreBytes
            else { throw KeychainSecretStoreError.invalidData }
            try keychain.saveSecret(encoded, service: service, account: key)
        } else {
            try keychain.deleteSecret(service: service, account: key)
        }
        guard try loadRestoreValue(key) == value else { throw KeychainSecretStoreError.invalidData }
    }

    static func fingerprint(_ backup: CallRelationshipBackup) throws -> String {
        try digest(backup)
    }

    static func fingerprint(_ contact: CallRelationshipBackup.Contact) throws -> String {
        try digest(contact)
    }

    private func account(as signer: DeviceIdentitySigner) throws -> String {
        guard !cloud.container.isEmpty, !cloud.account.isEmpty, let owner = signer.principal else {
            throw GroupStorageError.identityConflict
        }
        return try Self.digest(Scope(cloud: cloud, owner: owner, deviceKey: signer.publicKey))
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try SHA256.hash(data: encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
