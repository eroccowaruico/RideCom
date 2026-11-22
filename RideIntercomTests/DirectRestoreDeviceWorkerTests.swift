#if os(macOS)
import CloudKit
import Foundation
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)))
    func replacementFetchesThePublishedDeviceAndBuildsARequest() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("restore-holder")
            let original = GroupDeliveryTestIdentity("restore-original")
            let replacement = GroupDeliveryTestIdentity("restore-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let publisher = try holder.harness(knowing: []).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: []).viewModel
            defer { publisher.disconnect(); old.disconnect(); new.disconnect() }
            try confirmRestoreContact(from: publisher, to: old)
            let contactID = try #require(old.savedRemoteUsers.first?.id)
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            let oldSigner = try original.signer
            let now = Date()
            let backup = try old.groupRepository.callRelationshipBackup(as: oldSigner, now: now.timeIntervalSince1970)
            let cloud = CloudAccountFixture(account: "restore-cloud-fixture")
            _ = try await cloud.store.save(backup, replacing: nil, as: oldSigner, now: now.timeIntervalSince1970)
            let session = cloud.session()
            session.bind(to: new)
            defer { session.bind(to: nil) }
            await session.task?.value
            await new.callRelationshipBackupSync?.task?.value
            let client = InternetAccountClient(session: workerSession())
            #expect(try await session.prepareDirectRestore(for: contactID, from: backup, using: client) == nil)

            let publication = try #require(try publisher.groupRepository.directRestoreDevicePublication(
                for: publisherContact, as: holder.signer, now: Date()))
            let access = try #require(try holder.store.notificationAccess(memberID: holder.memberID))
            try await client.publishDirectRestoreDevice(publication, access: access)
            let prepared = try #require(try await session.prepareDirectRestore(
                for: contactID, from: backup, using: client))
            #expect(prepared.recipient.deviceID == (try holder.signer.identity?.deviceID))
            let trust = try #require(try holder.store.identityTrust())
            let requester = try prepared.request.verifiedDirectRequester(addressedTo: holder.signer,
                                                                          trust: trust, now: Date())
            #expect(requester == (try replacement.principal))
            try await rejectRestoreAfterBackupChanges(in: cloud, using: client, session: session,
                                                       backup: backup, contactID: contactID)

            try #require(publisher.removeSavedUser(publisherContact))
            try await client.revokeDirectRestoreDevice(publication.withdrawal, access: access)
            #expect(try await session.prepareDirectRestore(for: contactID, from: backup, using: client) == nil)
        }
    }

    private func confirmRestoreContact(from publisher: IntercomViewModel, to old: IntercomViewModel) throws {
        for model in [publisher, old] {
            model.groupDeliveryClient = nil
            model.allowsNearbyGroupDelivery = false
            model.contactSessionFactory = { RecordingCallSession() }
        }
        try old.acceptContactInviteURL(try #require(publisher.makeContactInviteURL()))
        let id = try #require(old.pendingContactInvitations.first?.id)
        let reply = try old.contactReplyURLForSharing(id, expectedAccountAccessID: old.accountAccessID)
        try publisher.receiveContactReplyURL(reply)
        let acknowledgement = try publisher.contactReplyURLForSharing(
            id, expectedAccountAccessID: publisher.accountAccessID)
        try old.receiveContactReplyURL(acknowledgement)
        for model in [publisher, old] {
            let person = try #require(model.savedRemoteUsers.first?.id)
            try #require(model.selectUser(person, connectIfIdle: false))
        }
    }

    private func rejectRestoreAfterBackupChanges(
        in cloud: CloudAccountFixture, using client: InternetAccountClient,
        session: CloudKitCallRelationshipBackupSession,
        backup: CallRelationshipBackup, contactID: UUID
    ) async throws {
        let record = try #require(cloud.records.values.first)
        let previous = try #require(record.encryptedValues["payload"] as? NSData)
        let removed = try JSONEncoder().encode(backup.removingContacts([contactID]))
        let gate = ManualAsyncGate()
        GroupWorkerHTTPBridge.holdNextRestoreDeviceRead.withLock { $0 = gate }
        defer {
            record.encryptedValues["payload"] = previous
            GroupWorkerHTTPBridge.holdNextRestoreDeviceRead.withLock { $0 = nil }
            Task { await gate.release() }
        }
        let reading = Task { try await session.prepareDirectRestore(for: contactID, from: backup, using: client) }
        await gate.waitForEntry()
        record.encryptedValues["payload"] = removed as NSData
        await gate.release()
        await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.backupChanged) { try await reading.value }
    }
}
#endif
