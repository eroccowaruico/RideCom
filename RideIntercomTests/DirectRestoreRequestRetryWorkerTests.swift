#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)))
    func selectedRestoreResendsTheSavedRequestAfterAnInterruptedReply() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("retry-holder")
            let original = GroupDeliveryTestIdentity("retry-original")
            let replacement = GroupDeliveryTestIdentity("retry-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let publisher = try holder.harness(knowing: []).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { publisher.disconnect(); old.disconnect(); new.disconnect() }
            try confirmRestoreContact(from: publisher, to: old)
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            let client = InternetAccountClient(session: workerSession())
            let publisherAccess = try #require(try holder.store.notificationAccess(memberID: holder.memberID))
            try #require(try await publisher.publishTrackedDirectRestoreDevice(for: publisherContact, using: client))

            let cloud = CloudAccountFixture(account: "retry-cloud")
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: cloud)
            let contact = try #require(backup.contacts.first?.id)
            let keys = DictionaryKeychain()
            let reader = cloud.session(keychain: keys, directRestoreClient: client)
            reader.bind(to: new)
            defer { reader.bind(to: nil) }
            await reader.task?.value
            let attempts = GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 }
            GroupWorkerHTTPBridge.interruptNextRestoreRelayReply.withLock { $0 = true }
            defer { GroupWorkerHTTPBridge.interruptNextRestoreRelayReply.withLock { $0 = false } }
            try await reader.selectDirectRestore(contact, from: backup)
            await #expect(throws: URLError.self) { try await reader.directRestorePreparation?.value }
            let first = try #require(try await client.directRestoreInbox(access: publisherAccess).first)
            reader.bind(to: nil)

            let reopened = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { reopened.disconnect() }
            let restarted = cloud.session(keychain: keys, directRestoreClient: client)
            restarted.bind(to: reopened)
            defer { restarted.bind(to: nil) }
            await restarted.task?.value
            await verifyRestoreReady(restarted)
            let retried = try await client.directRestoreInbox(access: publisherAccess)
            let keptOnlyFirst = retried.count == 1 && retried.first?.id == first.id
                && retried.first?.packet == first.packet
            #expect(keptOnlyFirst)
            #expect(GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 } == attempts + 2)
            restarted.retrySelectedDirectRestore()
            await verifyRestoreReady(restarted)
            #expect(GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 } == attempts + 2)
        }
    }

    private func verifyRestoreReady(_ session: CloudKitCallRelationshipBackupSession) async {
        let result = try? await session.directRestorePreparation?.value
        if case .ready? = result { return }
        Issue.record("The saved request should be ready for its response")
    }
}
#endif
