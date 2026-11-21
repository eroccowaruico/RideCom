import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryFlowTests {
    enum NearbyContactDeletionOrder: CaseIterable { case ordinary, responseLost, bothRemoved }

    @Test(.timeLimit(.minutes(1)), arguments: NearbyContactDeletionOrder.allCases)
    func nearbyContactDeletionResumesAfterRestartAndClearsTheSendQueue(order: NearbyContactDeletionOrder) async throws {
        let authorDevice = GroupDeliveryTestIdentity("nearby-contact-removal-author")
        let recipientDevice = GroupDeliveryTestIdentity("nearby-contact-removal-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        let sender = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        defer {
            sender.stopGroupDeliverySync()
            recipient.stopGroupDeliverySync()
        }
        for model in [sender, recipient] {
            model.groupDeliveryClient = nil
            model.contactSessionFactory = { RecordingCallSession() }
        }
        try establishContact(sender: sender, recipient: recipient)
        #expect(sender.localAccountPrincipal == nil && recipient.localAccountPrincipal == nil)

        try expireNearbyContactDeletionWindow(on: sender, recipient: recipient)
        if order == .bothRemoved {
            recipient.allowsNearbyGroupDelivery = false
            try #require(recipient.removeSavedUser(try #require(recipient.savedRemoteUsers.first).id))
        }

        let restarted = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        defer { restarted.stopGroupDeliverySync() }
        restarted.groupDeliveryClient = nil
        restarted.allowsNearbyGroupDelivery = true
        recipient.allowsNearbyGroupDelivery = true
        try #require(restarted.groupRepository.contactDeletions.count == 1)

        var receivingModel = recipient
        defer { receivingModel.stopGroupDeliverySync() }
        if order == .bothRemoved {
            receivingModel = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
            receivingModel.groupDeliveryClient = nil
            receivingModel.allowsNearbyGroupDelivery = true
        }
        if order == .responseLost {
            receivingModel = try await reopenAfterLosingNearbyContactDeletionReceipt(
                on: restarted, recipient: recipient, author: authorDevice, recipientDevice: recipientDevice
            )
        }

        await checkNearbyDeletionQueueDrains(sender: restarted, recipient: receivingModel, order: order)
    }

    private func checkNearbyDeletionQueueDrains(
        sender restarted: IntercomViewModel,
        recipient receivingModel: IntercomViewModel,
        order: NearbyContactDeletionOrder
    ) async {
        receivingModel.setNearbyGroupDeliveryForeground(true)
        restarted.setNearbyGroupDeliveryForeground(true)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            restarted.groupRepository.contactDeletions.isEmpty
                && receivingModel.groupRepository.contactDeletions.isEmpty
        }
        #expect(restarted.groupRepository.contactDeletions.isEmpty)
        #expect(receivingModel.groupRepository.contactDeletions.isEmpty)
        #expect(receivingModel.savedRemoteUsers.isEmpty)
        #expect(receivingModel.groups.isEmpty)
        #expect(restarted.nearbyGroupDeliveryWindow == nil)
        if order == .bothRemoved {
            #expect(restarted.groupRepository.contactDeletionFormerPairs.isEmpty)
            #expect(receivingModel.groupRepository.contactDeletionFormerPairs.isEmpty)
        }
    }

    private func expireNearbyContactDeletionWindow(on sender: IntercomViewModel, recipient: IntercomViewModel) throws {
        var expiration: (() -> Void)?
        var released = 0
        sender.beginGroupDeliveryBackgroundTime = {
            expiration = $0
            return { released += 1 }
        }
        sender.allowsNearbyGroupDelivery = true
        let person = try #require(sender.savedRemoteUsers.first)
        try #require(sender.removeSavedUser(person.id))
        try #require(sender.groupRepository.contactDeletions.count == 1)
        // No recipient is browsing yet. The window may close while the send remains durable.
        let expire = try #require(expiration)
        expire()
        #expect(released == 1)
        #expect(sender.nearbyGroupDeliveryExchange == nil)
        #expect(recipient.savedRemoteUsers.count == 1)
    }

    private func reopenAfterLosingNearbyContactDeletionReceipt(
        on restarted: IntercomViewModel,
        recipient: IntercomViewModel,
        author authorDevice: GroupDeliveryTestIdentity,
        recipientDevice: GroupDeliveryTestIdentity
    ) async throws -> IntercomViewModel {
        let captured = Mutex<ContactDeletionNotice?>(nil)
        let interceptor = RTCLocalDataChannel(
            localID: .init(rawValue: recipientDevice.memberID),
            knownPeers: recipient.nearbyGroupDeliveryCredentials()
        ) { event in
            if case .message(let data, _) = event,
                case .contactDeletion(let notice) = try? JSONDecoder().decode(
                    NearbyGroupDeliveryFrame.self, from: data) {
                captured.withLock { $0 = notice }
            }
        }
        defer { interceptor.stop() }
        interceptor.start()
        restarted.setNearbyGroupDeliveryForeground(true)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) { captured.withLock { $0 != nil } }
        let delivered = try #require(captured.withLock { $0 })
        _ = try recipient.receiveContactDeletion(delivered, from: authorDevice.memberID)
        #expect(recipient.savedRemoteUsers.isEmpty)
        #expect(restarted.groupRepository.contactDeletions.count == 1, "The saved receipt was not sent back")
        restarted.setNearbyGroupDeliveryForeground(false)
        restarted.stopGroupDeliverySync()

        let receivingModel = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        receivingModel.groupDeliveryClient = nil
        receivingModel.allowsNearbyGroupDelivery = true
        #expect(receivingModel.savedRemoteUsers.isEmpty)
        #expect(receivingModel.groupRepository.contactDeletionReceipts.count == 1)
        return receivingModel
    }
}
