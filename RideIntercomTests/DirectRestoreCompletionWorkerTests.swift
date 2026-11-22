#if os(macOS)
import AudioCore
import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)))
    func restoresTwoContactsAndKeepsADeletedContactOutAfterRestart() async throws {
        try await withWorker(directRestore: true) {
            let first = GroupDeliveryTestIdentity("multiple-first")
            let second = GroupDeliveryTestIdentity("multiple-second")
            let original = GroupDeliveryTestIdentity("multiple-original")
            let replacement = GroupDeliveryTestIdentity("multiple-replacement")
            defer { [first, second, original, replacement].forEach { $0.remove() } }
            for identity in [first, second, original] { try await register(identity) }
            try await register(replacement, appleSubject: original.memberID)
            let firstHolder = try first.harness(knowing: []).viewModel
            let secondHolder = try second.harness(knowing: []).viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { [firstHolder, secondHolder, old, new].forEach { $0.disconnect() } }
            let client = InternetAccountClient(session: workerSession())
            let firstID = try await prepareRestorableContact(from: firstHolder, in: old, using: client)
            let secondID = try await prepareRestorableContact(from: secondHolder, in: old, using: client)
            let source = CloudAccountFixture(account: "multiple-source")
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: source)
            let keys = DictionaryKeychain()
            let makeReader = { source.session(keychain: keys, directRestoreClient: client) }
            let originalKey = try await restoreSavedContact(firstID, from: backup,
                on: new, with: (firstHolder, first.signer), using: makeReader())
            try #require(new.renameSavedUser(firstID, displayName: "Retained choice"))
            try #require(new.createTalkGroup(name: "Existing group"))
            let groupID = try #require(new.selectedGroup?.id)
            let groupKey = try #require(try new.groupRepository.credential(for: groupID))

            let reopened = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { reopened.disconnect() }
            try #require(reopened.startCall(to: .group(groupID), accountAccessID: reopened.accountAccessID))
            let secondKey = try await restoreSavedContact(secondID, from: backup,
                on: reopened, with: (secondHolder, second.signer), using: makeReader())
            #expect(reopened.savedRemoteUsers.first { $0.id == firstID }?.localName == "Retained choice")
            #expect(try reopened.groupRepository.credential(for: originalKey.groupID) == originalKey)
            #expect(try reopened.groupRepository.credential(for: groupID) == groupKey)
            await reopened.callRelationshipBackupSync?.task?.value
            let saved = try await source.store.load(as: replacement.signer, now: Date().timeIntervalSince1970)
            #expect(saved?.backup == backup)

            try #require(reopened.removeSavedUser(firstID))
            let afterDeletion = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { afterDeletion.disconnect() }
            await assertCannotRestore([firstID, secondID], from: backup, on: afterDeletion, using: makeReader())
            #expect(try afterDeletion.groupRepository.credential(for: originalKey.groupID) == nil)
            #expect(try afterDeletion.groupRepository.credential(for: secondKey.groupID) == secondKey)
            #expect(try afterDeletion.groupRepository.credential(for: groupID) == groupKey)
        }
    }

    private func prepareRestorableContact(
        from holder: IntercomViewModel, in original: IntercomViewModel, using client: InternetAccountClient
    ) async throws -> UUID {
        try confirmRestoreContact(from: holder, to: original)
        let peer = try #require(holder.localAccountPrincipal)
        let contact = try #require(original.savedRemoteUsers.first { $0.principal == peer }?.id)
        try #require(original.selectUser(contact, connectIfIdle: false))
        let holderContact = try #require(holder.savedRemoteUsers.first?.id)
        try #require(try await holder.publishTrackedDirectRestoreDevice(for: holderContact, using: client))
        return contact
    }

    private func restoreSavedContact(
        _ id: UUID, from backup: CallRelationshipBackup,
        on model: IntercomViewModel, with holder: (model: IntercomViewModel, signer: DeviceIdentitySigner),
        using reader: CloudKitCallRelationshipBackupSession
    ) async throws -> GroupAccessCredential {
        let activeBeforeRestore = model.currentCallReference
        let client = try #require(reader.directRestoreClient)
        reader.bind(to: model)
        defer { reader.bind(to: nil) }
        await reader.task?.value
        try await reader.selectDirectRestore(id, from: backup)
        _ = try await reader.directRestorePreparation?.value
        try await answerRestoreOnStartup(on: holder.model, as: holder.signer, using: client)
        reader.retrySelectedDirectRestore()
        _ = try await reader.directRestorePreparation?.value
        #expect(model.currentCallReference == activeBeforeRestore)
        try #require(model.startCall(to: .user(id), accountAccessID: model.accountAccessID))
        let callID = try #require(holder.model.selectedGroup?.id)
        try #require(model.activeGroupID == callID)
        model.disconnect()
        let key = try #require(try holder.model.groupRepository.credential(for: callID))
        try #require(try model.groupRepository.credential(for: callID) == key)
        return key
    }

    private func assertCannotRestore(
        _ ids: [UUID], from backup: CallRelationshipBackup, on model: IntercomViewModel,
        using reader: CloudKitCallRelationshipBackupSession
    ) async {
        reader.bind(to: model)
        defer { reader.bind(to: nil) }
        await reader.task?.value
        let attempts = GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 }
        for id in ids {
            await #expect(throws: GroupStorageError.invalidUpdate) {
                try await reader.selectDirectRestore(id, from: backup)
            }
        }
        #expect(GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 } == attempts)
    }

    @Test(.timeLimit(.minutes(1)))
    func automaticRestoreFinishesReceiptAfterRestartWithoutRestoringAgain() async throws {
        try await withWorker(directRestore: true) {
            let holder = GroupDeliveryTestIdentity("completion-holder")
            let original = GroupDeliveryTestIdentity("completion-original")
            let replacement = GroupDeliveryTestIdentity("completion-replacement")
            defer { holder.remove(); original.remove(); replacement.remove() }
            try await register(holder)
            try await register(original)
            try await register(replacement, appleSubject: original.memberID)
            let holderHarness = try holder.harness(knowing: [])
            let publisher = holderHarness.viewModel
            let old = try original.harness(knowing: []).viewModel
            let new = try replacement.harness(knowing: [], onDisk: true).viewModel
            defer { publisher.disconnect(); old.disconnect(); new.disconnect() }
            try confirmRestoreContact(from: publisher, to: old)
            let client = InternetAccountClient(session: workerSession())
            let publisherContact = try #require(publisher.savedRemoteUsers.first?.id)
            try #require(try await publisher.publishTrackedDirectRestoreDevice(for: publisherContact, using: client))

            let source = CloudAccountFixture(account: "completion-source")
            let backup = try await saveRestoreBackup(of: old, as: original.signer, for: source)
            let contact = try #require(backup.contacts.first?.id)
            let keys = DictionaryKeychain()
            let reader = source.session(keychain: keys, directRestoreClient: client)
            reader.bind(to: new)
            defer { reader.bind(to: nil) }
            await reader.task?.value
            try await reader.selectDirectRestore(contact, from: backup)
            _ = try await reader.directRestorePreparation?.value

            try await answerRestoreOnStartup(on: publisher, as: holder.signer, using: client)
            let access = try #require(try replacement.store.notificationAccess(memberID: replacement.memberID))
            try await saveWithInterruptedRestoreReceipt(reader, using: client, access: access)
            let callID = try #require(publisher.selectedGroup?.id)
            let originalKey = try #require(try publisher.groupRepository.credential(for: callID))
            #expect(new.savedRemoteUsers.first?.id == contact)
            #expect(new.groupRepository.writableSnapshot?.completedDirectRestore != nil)
            #expect(try new.groupRepository.credential(for: callID) == originalKey)
            try #require(new.renameSavedUser(contact, displayName: "Retained choice"))
            reader.bind(to: nil)

            let reopenedHarness = try replacement.harness(knowing: [], onDisk: true)
            let reopened = reopenedHarness.viewModel
            defer { reopened.disconnect() }
            try await finishRestoreReceipt(on: reopened, in: source, with: keys, using: client)
            #expect(reopened.groupRepository.writableSnapshot?.completedDirectRestore == nil)
            #expect(reopened.savedRemoteUsers.first?.localName == "Retained choice")
            #expect(try reopened.groupRepository.credential(for: callID) == originalKey)
            #expect(try await client.directRestoreInbox(access: access).isEmpty)
            try await client.retireDirectRestorePacket(UUID().uuidString.lowercased(), access: access)
            try await assertRestoredCall(
                holderHarness, to: publisherContact, reopenedHarness, to: contact, callID: callID)
        }
    }

    private func assertRestoredCall(
        _ holder: AppTestSupport.Harness, to holderContact: UUID,
        _ replacement: AppTestSupport.Harness, to replacementContact: UUID, callID: UUID
    ) async throws {
        for (endpoint, contact) in [(holder, holderContact), (replacement, replacementContact)] {
            let model = endpoint.viewModel
            model.allowsNearbyGroupDelivery = false
            model.setRTCTransportRoutes([.multipeer])
            try #require(model.startCall(to: .user(contact), accountAccessID: model.accountAccessID))
            try #require(model.activeGroupID == callID)
            try #require(endpoint.callSession.connectedGroup?.id == callID)
        }
        let holderID = holder.viewModel.localMemberIdentity.memberID
        let replacementID = replacement.viewModel.localMemberIdentity.memberID
        holder.callSession.authenticate([replacementID])
        replacement.callSession.authenticate([holderID])
        #expect(holder.viewModel.callAccessAdmittedMemberships.isEmpty)
        #expect(replacement.viewModel.callAccessAdmittedMemberships.isEmpty)

        try exchangeCallProfile(verifier: holder, peer: replacement)
        try exchangeCallProfile(verifier: replacement, peer: holder)
        #expect(holder.viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue) == [replacementID])
        #expect(replacement.viewModel.callAccessAdmittedMemberships.keys.map(\.rawValue) == [holderID])
        try await assertRestoredAudio(from: holder, to: replacement, frequency: 440)
        try await assertRestoredAudio(from: replacement, to: holder, frequency: 660)
    }

    private func exchangeCallProfile(verifier: AppTestSupport.Harness, peer: AppTestSupport.Harness) throws {
        verifier.viewModel.sendPeerProfileChallenges()
        let challenge = try #require(verifier.callSession.sentApplicationDataMessages.last {
            $0.namespace == PeerProfileChallenge.namespace
        })
        peer.viewModel.handleTransportEvent(.receivedApplicationData(
            peerID: verifier.viewModel.localMemberIdentity.memberID, message: challenge))
        let signedProfile = try #require(peer.callSession.sentApplicationDataMessages.last {
            $0.namespace == SharedDisplayName.namespace
        })
        verifier.viewModel.handleTransportEvent(.receivedApplicationData(
            peerID: peer.viewModel.localMemberIdentity.memberID, message: signedProfile))
    }

    private func assertRestoredAudio(
        from sender: AppTestSupport.Harness, to receiver: AppTestSupport.Harness, frequency: Double
    ) async throws {
        await AppTestSupport.waitUntil {
            sender.viewModel.isAudioReady && receiver.viewModel.isAudioReady
        }
        try #require(sender.viewModel.isAudioReady && receiver.viewModel.isAudioReady)

        let rate = 48_000.0
        let frameCount = 960
        let started = Date().timeIntervalSince1970
        for index in 0..<12 {
            let offset = index * frameCount
            let samples = (0..<frameCount).map { sample in
                Float(sin(2 * .pi * frequency * Double(offset + sample) / rate)) * 0.5
            }
            sender.inputBackend.emit(.init(
                sequenceNumber: UInt64(index), format: .intercomPacketAudio,
                capturedAt: started + Double(offset) / rate, samples: samples))
            try await Task.sleep(for: .milliseconds(20))
        }
        await AppTestSupport.waitUntil { sender.callSession.sentAudioPackets.count >= 4 }
        let packets = sender.callSession.sentAudioPackets
        try #require(packets.count >= 4)
        let senderID = RTC.PeerID(rawValue: sender.viewModel.localMemberIdentity.memberID)
        let framesBeforeDelivery = receiver.outputBackend.scheduledFrames.count
        for packet in packets {
            receiver.callSession.receive(.init(peerID: senderID, packet: packet))
        }
        func receivedSound() -> Bool {
            receiver.outputBackend.scheduledFrames.dropFirst(framesBeforeDelivery).contains { frame in
                frame.samples.contains { abs($0) > 0.01 }
            }
        }
        await AppTestSupport.waitUntil { receivedSound() }
        #expect(receivedSound())
    }

    private func answerRestoreOnStartup(on model: IntercomViewModel, as signer: DeviceIdentitySigner,
                                        using client: InternetAccountClient) async throws {
        let target = CloudAccountFixture(account: "completion-target")
        _ = try await saveRestoreBackup(of: model, as: signer, for: target)
        model.groupDeliveryClient = client
        let session = target.session(directRestoreClient: client)
        session.bind(to: model)
        defer { session.bind(to: nil) }
        await session.task?.value
        #expect(try await session.directRestoreInboxTask?.value == 1)
    }

    private func saveWithInterruptedRestoreReceipt(
        _ session: CloudKitCallRelationshipBackupSession, using client: InternetAccountClient,
        access: CallNotificationServiceAccess
    ) async throws {
        GroupWorkerHTTPBridge.interruptNextRestoreRetirement.withLock { $0 = true }
        defer { GroupWorkerHTTPBridge.interruptNextRestoreRetirement.withLock { $0 = false } }
        session.retrySelectedDirectRestore()
        _ = try await session.directRestorePreparation?.value
        #expect(try await client.directRestoreInbox(access: access).count == 1)
    }

    private func finishRestoreReceipt(
        on model: IntercomViewModel, in cloud: CloudAccountFixture, with keys: DictionaryKeychain,
        using client: InternetAccountClient
    ) async throws {
        let attempts = GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 }
        let reader = cloud.session(keychain: keys, directRestoreClient: client)
        reader.bind(to: model)
        defer { reader.bind(to: nil) }
        await reader.task?.value
        _ = try await reader.directRestorePreparation?.value
        #expect(GroupWorkerHTTPBridge.restoreRelaySubmissionAttempts.withLock { $0 } == attempts)
    }
}
#endif
