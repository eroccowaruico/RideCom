#if os(macOS)
import CloudKit
import Foundation
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)))
    func selectedRestoreWaitsForAFreshDeviceCertificateAcrossRestart() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("expiry-holder")
            let original = GroupDeliveryTestIdentity("expiry-original")
            let replacement = GroupDeliveryTestIdentity("expiry-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let publisher = try holder.harness(knowing: []).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { publisher.disconnect(); old.disconnect(); new.disconnect() }
            try confirmRestoreContact(from: publisher, to: old)

            let source = CloudAccountFixture(account: "expiry-source")
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: source)
            let contact = try #require(backup.contacts.first)
            let client = InternetAccountClient(session: workerSession())
            let keys = DictionaryKeychain()
            let reader = source.session(keychain: keys, directRestoreClient: client)
            reader.bind(to: new)
            defer { reader.bind(to: nil) }
            await reader.task?.value
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            let publisherAccess = try #require(try holder.store.notificationAccess(memberID: holder.memberID))
            let expiry = try await publishShortLivedCertificate(
                from: publisher, for: publisherContact, using: client, access: publisherAccess)
            #expect(try await reader.prepareDirectRestore(for: contact.id, from: backup, using: client) != nil)
            try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow + 0.025)))

            try await reader.selectDirectRestore(contact.id, from: backup)
            try await requireWaitingForRestoreCertificate(reader)
            reader.bind(to: nil)
            let reopened = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { reopened.disconnect() }
            let restarted = source.session(keychain: keys, directRestoreClient: client)
            let owner = AppCallOwner(account: reopened.accountSession, viewModel: reopened, backupSession: restarted)
            defer { restarted.bind(to: nil) }
            await restarted.task?.value
            try await requireWaitingForRestoreCertificate(restarted)

            await republishRestoreCertificateOnStartup(publisher, using: client)
            owner.systemSurfaceIsForeground = true
            guard case let .ready(pending)? = try await restarted.directRestorePreparation?.value
            else { Issue.record("Returning to the app should prepare the same selection"); return }
            #expect(try await client.directRestoreInbox(access: publisherAccess).count == 1)

            try await removeAndReselectRestoreContact(contact.id, from: backup, in: source, with: restarted)
            try await rejectRequestFromPreviousSelection(pending, on: restarted, using: client, cloud: source)
        }
    }

    private func requireWaitingForRestoreCertificate(_ reader: CloudKitCallRelationshipBackupSession) async throws {
        let result = try await reader.directRestorePreparation?.value
        let waiting = if case .waitingForDevice? = result { true } else { false }
        try #require(waiting)
    }

    private func republishRestoreCertificateOnStartup(
        _ publisher: IntercomViewModel, using client: InternetAccountClient
    ) async {
        let owner = AppCallOwner(account: publisher.accountSession, viewModel: publisher,
                                 directRestoreDeviceClient: client)
        await owner.viewModel?.directRestoreDeviceSync?.task?.value
        owner.viewModel?.stopDirectRestoreDeviceSync()
    }

    private func publishShortLivedCertificate(
        from publisher: IntercomViewModel, for contact: UUID,
        using client: InternetAccountClient, access: CallNotificationServiceAccess
    ) async throws -> Date {
        let earlier = Date().addingTimeInterval(-86_396)
        let signer = try #require(try publisher.callRelationshipBackupSigner())
        let publication = try #require(try publisher.groupRepository.directRestoreDevicePublication(
            for: contact, as: signer, now: earlier))
        try await client.publishDirectRestoreDevice(publication, access: access)
        return Date(timeIntervalSince1970: Double(publication.expiresAt) / 1_000)
    }

    private func rejectRequestFromPreviousSelection(
        _ pending: CloudKitCallRelationshipBackupSession.PendingDirectRestore,
        on session: CloudKitCallRelationshipBackupSession, using client: InternetAccountClient,
        cloud: CloudAccountFixture
    ) async throws {
        await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.backupChanged) {
            try await session.sendRelayedDirectRestore(pending, using: client)
        }
        cloud.account = "different-cloud-account"
        cloud.center.post(name: .CKAccountChanged, object: nil)
        await session.task?.value
        guard case .noSelection? = try await session.directRestorePreparation?.value
        else { Issue.record("Another iCloud account should not open the saved selection"); return }
    }

    private func removeAndReselectRestoreContact(_ id: UUID, from backup: CallRelationshipBackup,
                                                 in source: CloudAccountFixture,
                                                 with session: CloudKitCallRelationshipBackupSession) async throws {
        let record = try #require(source.records.values.first)
        let removed = try JSONEncoder().encode(backup.removingContacts([id]))
        record.encryptedValues["payload"] = removed as NSData
        session.retrySelectedDirectRestore()
        guard case .selectionChanged? = try await session.directRestorePreparation?.value
        else { Issue.record("A removed contact should clear the selected restore"); return }
        session.retrySelectedDirectRestore()
        guard case .noSelection? = try await session.directRestorePreparation?.value
        else { Issue.record("The removed contact should stay cleared"); return }
        record.encryptedValues["payload"] = try JSONEncoder().encode(backup) as NSData
        try await session.selectDirectRestore(id, from: backup)
    }

    @Test(.timeLimit(.minutes(1)))
    func directRestoreDevicePublicationResumesFromSavedRelationships() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("automatic-holder")
            let original = GroupDeliveryTestIdentity("automatic-original")
            defer { holder.remove(); original.remove() }
            try await register(holder)
            try await register(original)
            let publisher = try holder.harness(knowing: [], onDisk: true).viewModel
            let old = try original.harness(knowing: []).viewModel
            let client = InternetAccountClient(session: workerSession())
            let attempts = GroupWorkerHTTPBridge.restoreDevicePublicationAttempts.withLock { $0 }
            defer { publisher.stopDirectRestoreDeviceSync(); publisher.disconnect(); old.disconnect() }

            let owner = AppCallOwner(account: publisher.accountSession, viewModel: publisher,
                                     directRestoreDeviceClient: client)
            let defaultOwner = AppCallOwner(account: old.accountSession, viewModel: old)
            await publisher.directRestoreDeviceSync?.task?.value
            #expect(GroupWorkerHTTPBridge.restoreDevicePublicationAttempts.withLock { $0 } == attempts)
            GroupWorkerHTTPBridge.interruptNextRestorePublication.withLock { $0 = true }
            defer { GroupWorkerHTTPBridge.interruptNextRestorePublication.withLock { $0 = false } }
            try confirmRestoreContact(from: publisher, to: old)
            await publisher.directRestoreDeviceSync?.task?.value
            #expect(GroupWorkerHTTPBridge.restoreDevicePublicationAttempts.withLock { $0 } == attempts + 1)
            #expect(defaultOwner.viewModel?.directRestoreDeviceSync == nil)

            let contactID = try #require(old.savedRemoteUsers.first?.id)
            let now = Date()
            let backup = try old.groupRepository.callRelationshipBackup(
                as: original.signer, now: now.timeIntervalSince1970)
            let address = try #require(try backup.directRestoreDeviceAddress(
                for: contactID, as: original.signer, now: now))
            let access = try #require(try original.store.notificationAccess(memberID: original.memberID))
            #expect(try await client.fetchDirectRestoreDevice(at: address, access: access) == nil)
            publisher.groupDeliveryNetworkPathChanged(isAvailable: false)
            publisher.groupDeliveryNetworkPathChanged(isAvailable: true)
            await publisher.directRestoreDeviceSync?.task?.value
            #expect(try await client.fetchDirectRestoreDevice(at: address, access: access) != nil)

            owner.systemSurfaceIsForeground = true
            await publisher.directRestoreDeviceSync?.task?.value
            #expect(GroupWorkerHTTPBridge.restoreDevicePublicationAttempts.withLock { $0 } == attempts + 2)
            try await withdrawAfterRestart(publisher, holder: holder, using: client)
            #expect(try await client.fetchDirectRestoreDevice(at: address, access: access) == nil)
        }
    }

    private func withdrawAfterRestart(_ publisher: IntercomViewModel, holder: GroupDeliveryTestIdentity,
                                      using client: InternetAccountClient) async throws {
        let contact = try #require(publisher.savedRemoteUsers.first?.id)
        publisher.stopDirectRestoreDeviceSync()
        try #require(publisher.removeSavedUser(contact))
        let reopened = try holder.harness(knowing: [], onDisk: true).viewModel
        defer { reopened.stopDirectRestoreDeviceSync(); reopened.disconnect() }
        let owner = AppCallOwner(account: reopened.accountSession, viewModel: reopened,
                                 directRestoreDeviceClient: client)
        await reopened.directRestoreDeviceSync?.task?.value
        #expect(owner.viewModel?.groupRepository.writableSnapshot?.directRestoreDevices.isEmpty == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementSavesTheOriginalCallKeyThroughTheWorker() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("relay-holder")
            let original = GroupDeliveryTestIdentity("relay-original")
            let replacement = GroupDeliveryTestIdentity("relay-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let publisher = try holder.harness(knowing: []).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: []).viewModel
            defer {
                publisher.stopGroupDeliverySync()
                publisher.disconnect(); old.disconnect(); new.disconnect()
            }
            try confirmRestoreContact(from: publisher, to: old)
            let contactID = try #require(old.savedRemoteUsers.first?.id)
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            let callID = try #require(publisher.selectedGroup?.id)
            let client = InternetAccountClient(session: workerSession())
            let access = try #require(try holder.store.notificationAccess(memberID: holder.memberID))
            let publication = try #require(try publisher.groupRepository.directRestoreDevicePublication(
                for: publisherContact, as: holder.signer, now: Date()))
            try await client.publishDirectRestoreDevice(publication, access: access)

            let source: CloudAccountFixture = .init(account: "source-fixture")
            let target: CloudAccountFixture = .init(account: "target-fixture")
            let reader = source.session(), responder = target.session()
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: source)
            _ = try await saveRestoreBackup(of: publisher, as: holder.signer, for: target)
            reader.bind(to: new); responder.bind(to: publisher)
            defer { reader.bind(to: nil); responder.bind(to: nil) }
            await reader.task?.value
            await responder.task?.value
            publisher.groupDeliveryClient = client

            let pending = try #require(try await reader.prepareRelayedDirectRestore(
                for: contactID, from: backup, using: client))
            try await verifyRestoreExchange(pending, reader: reader, responder: responder, using: client)
            try await rejectSaveForChangedBackup(
                pending, reader: reader, using: client, source: source, removed: backup.removingContacts([contactID]))
            let readerAccess = try #require(try replacement.store.notificationAccess(memberID: replacement.memberID))
            try await verifyRestoreSaveWithInterruptedRetirement(
                pending, reader: reader, using: client, access: readerAccess)
            #expect(new.savedRemoteUsers.first?.id == contactID)
            let holderKey = try #require(try publisher.groupRepository.credential(for: callID))
            #expect(try new.groupRepository.credential(for: callID) == holderKey)
        }
    }

    func saveRestoreBackup(of model: IntercomViewModel, as signer: DeviceIdentitySigner,
                           for cloud: CloudAccountFixture) async throws -> CallRelationshipBackup {
        let now = Date().timeIntervalSince1970
        let backup = try model.groupRepository.callRelationshipBackup(as: signer, now: now)
        _ = try await cloud.store.save(backup, replacing: nil, as: signer, now: now)
        return backup
    }

    private func verifyRestoreExchange(
        _ pending: CloudKitCallRelationshipBackupSession.PendingDirectRestore,
        reader: CloudKitCallRelationshipBackupSession, responder: CloudKitCallRelationshipBackupSession,
        using client: InternetAccountClient
    ) async throws {
        try await reader.sendRelayedDirectRestore(pending, using: client)
        try await reader.sendRelayedDirectRestore(pending, using: client)
        #expect(try await reader.finishRelayedDirectRestore(pending, using: client) == false)
        #expect(try await responder.respondToNextRelayedDirectRestore(using: client))
        #expect(try await responder.respondToNextRelayedDirectRestore(using: client) == false)
    }

    private func rejectSaveForChangedBackup(
        _ pending: CloudKitCallRelationshipBackupSession.PendingDirectRestore,
        reader: CloudKitCallRelationshipBackupSession, using client: InternetAccountClient,
        source: CloudAccountFixture, removed: CallRelationshipBackup
    ) async throws {
        let record = try #require(source.records.values.first)
        let previous = try #require(record.encryptedValues["payload"] as? NSData)
        defer { record.encryptedValues["payload"] = previous }
        record.encryptedValues["payload"] = try JSONEncoder().encode(removed) as NSData
        await #expect(throws: CloudKitCallRelationshipBackupSession.Failure.backupChanged) {
            try await reader.finishRelayedDirectRestore(pending, using: client)
        }
    }

    private func verifyRestoreSaveWithInterruptedRetirement(
        _ pending: CloudKitCallRelationshipBackupSession.PendingDirectRestore,
        reader: CloudKitCallRelationshipBackupSession, using client: InternetAccountClient,
        access: CallNotificationServiceAccess
    ) async throws {
        GroupWorkerHTTPBridge.interruptNextRestoreRetirement.withLock { $0 = true }
        defer { GroupWorkerHTTPBridge.interruptNextRestoreRetirement.withLock { $0 = false } }
        #expect(try await reader.finishRelayedDirectRestore(pending, using: client))
        #expect(try await client.directRestoreInbox(access: access).count == 1)
        #expect(try await reader.finishRelayedDirectRestore(pending, using: client))
        #expect(try await client.directRestoreInbox(access: access).isEmpty)
    }

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
            let publisher = try holder.harness(knowing: [], onDisk: true).viewModel
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

            try #require(try await publisher.publishTrackedDirectRestoreDevice(for: publisherContact, using: client))
            let tracked = try #require(publisher.groupRepository.writableSnapshot?.directRestoreDevices.first)
            #expect(!tracked.withdrawalPending)
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
            try await retryRestoreWithdrawal(afterRemoving: publisherContact, on: holder, using: client)
            #expect(try await session.prepareDirectRestore(for: contactID, from: backup, using: client) == nil)
        }
    }

    private func retryRestoreWithdrawal(afterRemoving contactID: UUID, on holder: GroupDeliveryTestIdentity,
                                        using client: InternetAccountClient) async throws {
        let reopened = try holder.harness(knowing: [], onDisk: true).viewModel
        defer { reopened.disconnect() }
        #expect(reopened.savedRemoteUsers.allSatisfy { $0.id != contactID })
        #expect(reopened.groupRepository.writableSnapshot?.directRestoreDevices.first?.withdrawalPending == true)
        GroupWorkerHTTPBridge.interruptNextRestoreWithdrawal.withLock { $0 = true }
        defer { GroupWorkerHTTPBridge.interruptNextRestoreWithdrawal.withLock { $0 = false } }
        await #expect(throws: URLError.self) {
            try await reopened.synchronizeDirectRestoreDeviceWithdrawals(using: client)
        }
        let retry = try holder.harness(knowing: [], onDisk: true).viewModel
        defer { retry.disconnect() }
        #expect(retry.groupRepository.writableSnapshot?.directRestoreDevices.first?.withdrawalPending == true)
        try await retry.synchronizeDirectRestoreDeviceWithdrawals(using: client)
        #expect(retry.groupRepository.writableSnapshot?.directRestoreDevices.isEmpty == true)
    }

    func confirmRestoreContact(from publisher: IntercomViewModel, to old: IntercomViewModel) throws {
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
