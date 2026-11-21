import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupTransactionTests {
    @Test func invalidProposedGroupDoesNotMakeCommittedDataCorrupt() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        var group = try fixture.group()
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        let original = try Data(contentsOf: fixture.file.url)
        group.name = ""
        do {
            try fixture.repository.save([group])
            Issue.record("Invalid proposed group must not be saved")
        } catch {
            #expect(GroupStorageIssue.classify(error) != .corrupted)
        }
        #expect(try Data(contentsOf: fixture.file.url) == original)
        let saved = try #require(try fixture.restart().load(localMemberID: "local").first)
        #expect(saved.name == "Saved")
        #expect(throws: GroupStorageError.invalidUpdate) { try fixture.repository.save([saved, saved]) }
        #expect(try Data(contentsOf: fixture.file.url) == original)
    }

    @Test func committedSnapshotKeepsOldKeyUntilReplacementAndSweepsOrphans() throws {
        let fixture = try GroupStorageFixture()
        defer { fixture.remove() }
        let group = try fixture.group()
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "old"))
        let old = try #require(try fixture.store.read()?.groups.first?.credentialReference)
        fixture.store.failCommit = true
        #expect(throws: (any Error).self) {
            try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "new"))
        }
        #expect(try fixture.keys.secret(reference: old) == "old")
        fixture.store.failCommit = false
        let restarted = fixture.restart()
        #expect(try restarted.load(localMemberID: "local").count == 1)
        #expect(try restarted.credential(for: group.id)?.secret == "old")
        #expect(fixture.keys.references() == [old])
        try restarted.save([group], credential: .init(groupID: group.id, secret: "new"))
        #expect(try restarted.credential(for: group.id)?.secret == "new")
        #expect(try fixture.keys.secret(reference: old) == nil)
    }

    @Test func cleanupFailureDoesNotRollBackCommitOrReviveDeletedGroup() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try fixture.group()
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        fixture.keys.failDeleting = true
        try fixture.repository.delete(group.id, remaining: [])
        #expect(try fixture.restart().load(localMemberID: "local").isEmpty)
        #expect(!fixture.keys.references().isEmpty)
        fixture.keys.failDeleting = false
        _ = try fixture.restart().load(localMemberID: "local")
        #expect(fixture.keys.references().isEmpty)
    }

    @Test func corruptManifestPreservesKeysUntilExplicitReset() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try fixture.group()
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        let bytes = Data("{broken".utf8)
        try bytes.write(to: fixture.file.url)
        let restarted = fixture.restart()
        #expect(throws: (any Error).self) { try restarted.load(localMemberID: "local") }
        #expect(!fixture.keys.references().isEmpty)
        try restarted.reset()
        #expect(try restarted.load(localMemberID: "local").isEmpty)
        #expect(fixture.keys.references().isEmpty)
        let archives = try FileManager.default.contentsOfDirectory(
            at: fixture.directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("groups-corrupt-") }
        #expect(archives.count == 1)
        #expect(try Data(contentsOf: #require(archives.first)) == bytes)
    }
}
