#if os(macOS)
import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
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
            try assertRestoredCall(
                holderHarness, to: publisherContact, reopenedHarness, to: contact, callID: callID)
        }
    }

    private func assertRestoredCall(
        _ holder: AppTestSupport.Harness, to holderContact: UUID,
        _ replacement: AppTestSupport.Harness, to replacementContact: UUID, callID: UUID
    ) throws {
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
