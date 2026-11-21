import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupMigrationTests {
    @Test func version22PreservesAQueuedInternetReceiptWhenAddingFormerPairs() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var old = try #require(try f.file.read())
        old.version = 22
        let local = testIdentitySigner("local"), peer = testIdentitySigner("peer")
        let owner = AccountPrincipal(issuer: "https://ride.example", userID: String(repeating: "a", count: 64))
        let recipient = AccountPrincipal(issuer: owner.issuer, userID: String(repeating: "b", count: 64))
        let secret = "migration-receipt-pair-key"
        let notice = try ContactDeletionNotice(signer: peer, recipientMemberID: local.memberID,
            recipientKey: local.publicKey, pairSecret: secret, now: Date())
        let receipt = try ContactDeletionReceipt(for: notice, recipient: local)
        let address = try #require(ContactDeletionRelayAddress(owner: owner, recipient: recipient, pairSecret: secret,
            senderID: peer.memberID, recipientID: local.memberID))
        let relay = try ContactDeletionRelayReceipt(receipt: receipt, address: address, signer: local)
        old.contactDeletionReceipts = [receipt]
        old.contactDeletionRelayReceipts = [relay]
        try f.file.commit(old)

        _ = try f.restart().load(localMemberID: "local")
        let migrated = try #require(try f.file.read())
        #expect(migrated.version == GroupSnapshot.currentVersion)
        #expect(migrated.contactDeletionReceipts == [receipt] && migrated.contactDeletionRelayReceipts == [relay])
        #expect(migrated.contactDeletionFormerPairs.isEmpty)
    }

    @Test func version21PreservesTheOriginalPacketWhenAddingRelayReceipts() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var old = try #require(try f.file.read())
        old.version = 21
        let local = testIdentitySigner("local"), peer = testIdentitySigner("peer")
        let owner = AccountPrincipal(issuer: "https://ride.example", userID: String(repeating: "a", count: 64))
        let recipient = AccountPrincipal(issuer: owner.issuer, userID: String(repeating: "b", count: 64))
        let secret = "migration-pair-key"
        let notice = try ContactDeletionNotice(signer: local, recipientMemberID: peer.memberID,
            recipientKey: peer.publicKey, pairSecret: secret, now: Date())
        let publication = try ContactDeletionPublication(notice: notice, sender: owner, recipient: recipient,
            signer: local, pairSecret: secret)
        old.contactDeletions = [notice]
        old.contactDeletionPublications = [publication]
        try f.file.commit(old)

        _ = try f.restart().load(localMemberID: "local")
        let migrated = try #require(try f.file.read())
        #expect(migrated.version == GroupSnapshot.currentVersion)
        #expect(migrated.contactDeletions == [notice] && migrated.contactDeletionPublications == [publication])
        #expect(migrated.contactDeletionRelayReceipts.isEmpty)
    }

    @Test func version18PreservesNearbyCancellationWhenAddingContactDeletions() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        var old = try #require(try f.file.read())
        old.version = 18
        let sender = AccountPrincipal(issuer: "https://ride.example", userID: String(repeating: "a", count: 64))
        let recipient = AccountPrincipal(issuer: sender.issuer, userID: String(repeating: "b", count: 64))
        let cancellation = GroupInvitationCancellation.Target(id: UUID(), groupID: UUID(), sender: sender,
            senderMemberID: "sender", recipient: recipient, recipientMemberID: "local", recipientKey: testIdentitySigner("local").publicKey,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970, envelopeDigest: Data(repeating: 1, count: 32))
        old.nearbyGroupCancellations = [cancellation]
        try f.file.commit(old)

        _ = try f.restart().load(localMemberID: "local")
        let migrated = try #require(try f.file.read())
        #expect(migrated.version == GroupSnapshot.currentVersion)
        #expect(migrated.nearbyGroupCancellations == [cancellation])
        #expect(migrated.contactDeletions.isEmpty)
    }

    @Test func version17PreservesRemovalReceiptsWhenAddingNearbyCancellationRecords() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "group-key"))
        var old = try #require(try f.file.read())
        old.version = 17
        let removal = GroupSnapshot.GroupRemovalReceipt(groupID: group.id, eventID: UUID(),
            signedDigest: Data(repeating: 1, count: 32), expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
        old.groupRemovalReceipts = [removal]
        try f.file.commit(old)

        let restarted = f.restart()
        _ = try restarted.load(localMemberID: "local")
        let migrated = try #require(try f.file.read())
        #expect(migrated.version == GroupSnapshot.currentVersion)
        #expect(migrated.groupRemovalReceipts == [removal] && migrated.nearbyGroupCancellations.isEmpty)
        #expect(try restarted.credential(for: group.id)?.secret == "group-key")
    }

    @Test func version16KeepsTheGroupKeyAndTakenInvitationWhenAddingRemovalReceipts() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "group-key"))
        var old = try #require(try f.file.read())
        old.version = 16
        let link = GroupSnapshot.GroupLinkReceipt(groupID: group.id, receiptID: UUID(), expiresAt: nil, retired: true)
        old.groupLinkReceipts = [link]
        try f.file.commit(old)

        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try restarted.credential(for: group.id)?.secret == "group-key")
        let migrated = try #require(try f.file.read())
        #expect(migrated.version == GroupSnapshot.currentVersion)
        #expect(migrated.groupLinkReceipts == [link] && migrated.groupRemovalReceipts.isEmpty)
    }

    @Test func validJSONWithInvalidGroupIdentityOffersCorruptionRecovery() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        var snapshot = GroupSnapshot(groups: [.init(group)])
        snapshot.groups[0].name = ""
        try JSONEncoder().encode(snapshot).write(to: f.file.url)
        do {
            _ = try f.restart().load(localMemberID: "local")
            Issue.record("Invalid saved name must fail loading")
        } catch {
            #expect(GroupStorageIssue.classify(error) == .corrupted)
        }
    }

    @Test func emptyStoreInitializationCanBeRetriedAfterCommitFailure() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.file.url)
        let repository = f.restart()
        f.store.failCommit = true
        #expect(throws: IntercomGroupError.storageUnavailable) { try repository.load(localMemberID: "local") }
        #expect(try f.file.read() == nil)
        #expect(f.keys.references().isEmpty)
        f.store.failCommit = false
        #expect(try repository.load(localMemberID: "local").isEmpty)
        let initialized = try #require(try f.file.read())
        #expect(initialized.version == GroupSnapshot.currentVersion)
        #expect(initialized.groups.isEmpty && initialized.users.isEmpty)
        #expect(try f.restart().load(localMemberID: "local").isEmpty)
        #expect(try f.file.read() == initialized)
    }

    @Test func interruptionAfterCommitKeepsNewKeyAndNeverRollsBack() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "old"))
        f.store.failAfterCommit = true
        #expect(throws: (any Error).self) { try f.repository.save([group], credential: .init(groupID: group.id, secret: "new")) }
        f.store.failAfterCommit = false
        let restarted = f.restart()
        _ = try restarted.load(localMemberID: "local")
        #expect(try restarted.credential(for: group.id)?.secret == "new")
        #expect(f.keys.values.values.sorted() == ["new"])
    }

    @Test func missingKeysAreDifferentFromTemporarilyUnavailableKeys() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        f.keys.failReading = true
        let restarted = f.restart()
        #expect(throws: (any Error).self) { try restarted.load(localMemberID: "local") }
        #expect(f.keys.values.count == 1)
        f.keys.failReading = false
        f.keys.values.removeAll()
        #expect(try restarted.load(localMemberID: "local").count == 1)
        #expect(restarted.missingCredentialGroupIDs == [group.id])
        #expect(try restarted.credential(for: group.id) == nil)
        try restarted.save([group], credential: .init(groupID: group.id, secret: "reinvited"))
        #expect(restarted.missingCredentialGroupIDs.isEmpty)
    }

    @Test func newerSchemaRefusesResetAndCorruptManifestIsArchivedBeforeReset() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "group-key"))
        let references = f.keys.references()
        let newer = Data("{\"version\":99}".utf8)
        try newer.write(to: f.file.url)
        #expect(throws: GroupStorageError.unsupportedVersion) { try f.restart().reset() }
        #expect(try Data(contentsOf: f.file.url) == newer)
        let broken = Data("broken".utf8)
        try broken.write(to: f.file.url)
        f.store.failArchive = true
        #expect(throws: (any Error).self) { try f.restart().reset() }
        #expect(try Data(contentsOf: f.file.url) == broken)
        #expect(f.keys.references() == references)
        f.store.failArchive = false
        try f.restart().reset()
        let archive = try #require(try FileManager.default.contentsOfDirectory(at: f.directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("groups-corrupt-") && $0.pathExtension == "json" })
        #expect(try Data(contentsOf: archive) == broken)
        #expect(try f.restart().load(localMemberID: "local").isEmpty)
        #expect(f.keys.references().isEmpty)
    }

    @Test func concurrentStoreIsBusyAndStaleRepositoryMustReload() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let otherFile = FileGroupStore(directory: f.directory)
        try f.file.lock()
        #expect(throws: GroupStorageError.busy) { try otherFile.lock() }
        f.file.unlock()
        let other = GroupRepository(store: otherFile, credentials: f.keys)
        _ = try other.load(localMemberID: "local")
        let group = try f.group()
        try f.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        #expect(throws: GroupStorageError.changedByAnotherProcess) { try other.save([]) }
        #expect(try other.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try other.credential(for: group.id)?.secret == "key")
    }

    @Test func realKeychainVersionedStoreListsOnlyItsOwnNamespace() throws {
        let namespace = "RideIntercom.fixture.\(UUID())"
        let store = KeychainGroupCredentialStore(namespace: namespace)
        let reference = UUID()
        defer { try? store.delete(reference: reference) }
        try store.saveSecret("fixture-secret", reference: reference)
        #expect(try store.secret(reference: reference) == "fixture-secret")
        #expect(try store.references() == [reference])
        #expect(throws: GroupStorageError.verificationFailed) { try store.saveSecret("overwrite", reference: reference) }
        try store.delete(reference: reference)
        #expect(try store.references().isEmpty)
    }
}

final class DictionaryKeychain: KeychainSecretStoring {
    var failWriteAccount: String?
    private(set) var readCount = 0
    private var values: [String: [String: String]] = [:]
    func accounts(service: String) -> [String] { Array(values[service, default: [:]].keys) }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws {
        if account == failWriteAccount { throw KeychainSecretStoreError.invalidData }
        values[service, default: [:]][account] = secret
    }
    func secret(service: String, account: String) throws -> String? { readCount += 1; return values[service]?[account] }
    func deleteSecret(service: String, account: String) throws { values[service]?[account] = nil }
}
