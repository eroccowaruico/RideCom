#if os(macOS)
import CloudKit
import Foundation
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    enum RestoreReplyChange: CaseIterable, Sendable { case unchanged, removed, rotatedKey }

    @Test(.timeLimit(.minutes(1)), arguments: RestoreReplyChange.allCases)
    func responderResumesTheSameReplyOnlyWhileTheContactIsStillAuthorized(change: RestoreReplyChange) async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("response-holder")
            let original = GroupDeliveryTestIdentity("response-original")
            let replacement = GroupDeliveryTestIdentity("response-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let publisher = try holder.harness(knowing: [], onDisk: true).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: []).viewModel
            defer { publisher.disconnect(); old.disconnect(); new.disconnect() }
            try confirmRestoreContact(from: publisher, to: old)
            let client = InternetAccountClient(session: workerSession())
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            try #require(try await publisher.publishTrackedDirectRestoreDevice(for: publisherContact, using: client))

            let source = CloudAccountFixture(account: "response-source")
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: source)
            let reader = source.session()
            reader.bind(to: new)
            defer { reader.bind(to: nil) }
            await reader.task?.value
            let contact = try #require(backup.contacts.first?.id)
            let pending = try #require(try await reader.prepareRelayedDirectRestore(
                for: contact, from: backup, using: client))
            try await reader.sendRelayedDirectRestore(pending, using: client)

            let target = CloudAccountFixture(account: "response-target")
            let publisherBackup = try await saveRestoreBackup(of: publisher, as: holder.signer, for: target)
            let savedKeys = DictionaryKeychain()
            try await interruptAutomaticRestoreReply(on: publisher, in: target, keys: savedKeys, using: client)
            let access = try #require(try replacement.store.notificationAccess(memberID: replacement.memberID))
            let first = try #require(try await client.directRestoreInbox(access: access).first)
            let attempts = GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 }
            try changeRestoreAuthorization(change, on: publisher, in: target,
                                           backup: publisherBackup, contact: publisherContact)
            let reopened = try holder.harness(knowing: [], onDisk: true).viewModel
            defer { reopened.disconnect() }
            try await resumeAutomaticRestoreReply(on: reopened, in: target, keys: savedKeys, using: client)
            let inbox = try await client.directRestoreInbox(access: access)
            let keptOnlyFirst = inbox.count == 1 && inbox.first?.id == first.id && inbox.first?.packet == first.packet
            #expect(keptOnlyFirst)
            let sends = GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 } - attempts
            #expect(sends == (change == .unchanged ? 1 : 0))
            let holderAccess = try #require(try holder.store.notificationAccess(memberID: holder.memberID))
            #expect(try await client.directRestoreInbox(access: holderAccess).count == (change == .unchanged ? 0 : 1))
        }
    }

    private func changeRestoreAuthorization(
        _ change: RestoreReplyChange, on model: IntercomViewModel, in cloud: CloudAccountFixture,
        backup: CallRelationshipBackup, contact: UUID
    ) throws {
        switch change {
        case .unchanged:
            break
        case .removed:
            let record = try #require(cloud.records.values.first)
            record.encryptedValues["payload"] = try JSONEncoder().encode(backup.removingContacts([contact])) as NSData
        case .rotatedKey:
            let callID = try #require(model.selectedGroup?.id)
            let replacementKey = Data(repeating: 0x77, count: 32).base64EncodedString()
            try model.groupRepository.update(model.groups, credential: .init(groupID: callID, secret: replacementKey))
        }
    }

    private func interruptAutomaticRestoreReply(
        on model: IntercomViewModel, in cloud: CloudAccountFixture, keys: DictionaryKeychain,
        using client: InternetAccountClient
    ) async throws {
        model.groupDeliveryClient = client
        let session = cloud.session(keychain: keys, directRestoreClient: client)
        GroupWorkerHTTPBridge.interruptNextRestoreRelayReply.withLock { $0 = true }
        defer { GroupWorkerHTTPBridge.interruptNextRestoreRelayReply.withLock { $0 = false } }
        session.bind(to: model)
        defer { session.bind(to: nil) }
        await session.task?.value
        await #expect(throws: URLError.self) { try await session.directRestoreInboxTask?.value }
    }

    private func resumeAutomaticRestoreReply(
        on model: IntercomViewModel, in cloud: CloudAccountFixture, keys: DictionaryKeychain,
        using client: InternetAccountClient
    ) async throws {
        model.groupDeliveryClient = client
        let session = cloud.session(keychain: keys, directRestoreClient: client)
        session.bind(to: model)
        defer { session.bind(to: nil) }
        await session.task?.value
        _ = try await session.directRestoreInboxTask?.value
    }
}
#endif
