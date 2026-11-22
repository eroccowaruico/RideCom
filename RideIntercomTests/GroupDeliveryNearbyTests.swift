import CallControl
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test(.timeLimit(.minutes(1)))
    func savesAndDeliversToTheRegisteredPeerFromForegroundWithoutInternet() async throws {
        let authorDevice = GroupDeliveryTestIdentity("automatic-nearby-sender")
        let recipientDevice = GroupDeliveryTestIdentity("automatic-nearby-recipient")
        defer { authorDevice.remove(); recipientDevice.remove() }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync(); sender.disconnect() }
        for model in [sender, recipient] {
            model.groupDeliveryClient = nil
            model.allowsNearbyGroupDelivery = true
        }
        var requested = 0
        var ended = 0
        sender.beginGroupDeliveryBackgroundTime = { _ in
            requested += 1
            return { ended += 1 }
        }
        recipient.setGroupDeliveryForeground(true)
        sender.setGroupDeliveryForeground(true)
        try #require(sender.createTalkGroup(name: "Trail riders", userIDs: [recipientDevice.personID]))
        let delivery = try #require(sender.groupRepository.groupDeliveries.first)
        #expect(requested == 1, "Time is requested before returning from the save")
        let callAfterSave = sender.activeGroupID
        sender.setGroupDeliveryForeground(false)

        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            sender.groupRepository.groupDeliveries.first?.state == .received
        }
        try #require(sender.groupRepository.groupDeliveries.first?.state == .received)
        #expect(recipient.groups.map(\.id) == [delivery.groupID])
        #expect(
            sender.activeGroupID == callAfterSave && recipient.activeGroupID == nil && recipient.selectedGroup == nil)
        #expect(ended == 1, "Received delivery releases the save's additional execution time")

        let reopened = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        #expect(reopened.groups.map(\.id) == [delivery.groupID])
        #expect(try reopened.groupRepository.credential(for: delivery.groupID)
            == sender.groupRepository.credential(for: delivery.groupID))
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherSaveRenewsTheNearbyDeadlineWithoutReopeningTheExchange() async throws {
        let authorDevice = GroupDeliveryTestIdentity("renew-nearby-sender")
        let recipientDevice = GroupDeliveryTestIdentity("renew-nearby-recipient")
        defer { authorDevice.remove(); recipientDevice.remove() }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync(); sender.disconnect() }
        for model in [sender, recipient] {
            model.groupDeliveryClient = nil
            model.allowsNearbyGroupDelivery = true
        }

        var requested = 0
        var ended = 0
        sender.beginGroupDeliveryBackgroundTime = { _ in
            requested += 1
            return { ended += 1 }
        }
        sender.setGroupDeliveryForeground(true)
        try #require(sender.createTalkGroup(name: "First group", userIDs: [recipientDevice.personID]))
        let earlierTimer = try #require(sender.nearbyGroupDeliveryWindow?.timeout)
        let earlierExchange = try #require(sender.nearbyGroupDeliveryExchange?.id)

        try #require(sender.createTalkGroup(name: "Second group", userIDs: [recipientDevice.personID]))
        try #require(earlierTimer.isCancelled, "The first deadline must stop owning the newer save")
        await earlierTimer.value
        let renewedTimer = try #require(sender.nearbyGroupDeliveryWindow?.timeout)
        sender.requestGroupDeliverySync(.localChange)
        #expect(!renewedTimer.isCancelled, "Refreshing the same saved records must leave the finite deadline in place")
        #expect(sender.nearbyGroupDeliveryExchange?.id == earlierExchange)
        #expect(requested == 1)

        let deliveries = sender.groupRepository.groupDeliveries
        try #require(deliveries.count == 2)
        sender.setGroupDeliveryForeground(false)
        recipient.setGroupDeliveryForeground(true)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            sender.groupRepository.groupDeliveries.filter { $0.state == .received }.count == deliveries.count
        }
        #expect(sender.groupRepository.groupDeliveries.filter { $0.state == .received }.count == deliveries.count)
        #expect(Set(recipient.groups.map(\.id)) == Set(deliveries.map(\.groupID)))
        #expect(ended == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func nearbyDeliveryReachesTheNextDeviceWhileTheFirstSevenAreAbsent() async throws {
        let author = GroupDeliveryTestIdentity("batch-author")
        let reachable = GroupDeliveryTestIdentity("batch-reachable")
        let absent = "cdef123".map { GroupDeliveryTestIdentity("batch-absent-\($0)") }
        defer { ([author, reachable] + absent).forEach { $0.remove() } }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try reachable.authorizeFixture(userID: String(repeating: "b", count: 64))
        for (person, digit) in zip(absent, "cdef123") {
            try person.authorizeFixture(userID: String(repeating: String(digit), count: 64))
        }

        let sender = try author.harness(knowing: [reachable] + absent, onDisk: true).viewModel
        let receiver = try reachable.harness(knowing: [author], onDisk: true).viewModel
        defer { sender.stopGroupDeliverySync(); receiver.stopGroupDeliverySync(); sender.disconnect() }
        sender.groupDeliveryClient = nil
        receiver.groupDeliveryClient = nil
        receiver.allowsNearbyGroupDelivery = true
        var requested = 0
        sender.beginGroupDeliveryBackgroundTime = { _ in
            requested += 1
            return {}
        }

        sender.setGroupDeliveryForeground(true)
        try #require(sender.createTalkGroup(name: "Older group", userIDs: [reachable.personID]))
        let older = try #require(sender.groupRepository.groupDeliveries.first)
        sender.allowsNearbyGroupDelivery = true
        try #require(sender.createTalkGroup(name: "Recent group", userIDs: Set(absent.map(\.personID))))
        #expect(sender.nearbyGroupDeliveryExchange?.offeredPeers == Set(absent.map { PeerID(rawValue: $0.memberID) }))
        #expect(requested == 1)
        sender.setGroupDeliveryForeground(false)
        receiver.setGroupDeliveryForeground(true)

        await AppTestSupport.waitUntil(timeout: .seconds(14)) {
            sender.groupRepository.groupDeliveries.first(where: { $0.id == older.id })?.state == .received
        }
        #expect(sender.groupRepository.groupDeliveries.first(where: { $0.id == older.id })?.state == .received)
        #expect(sender.groupRepository.groupDeliveries.filter { $0.state == .pending }.count == absent.count)
        #expect(receiver.groups.map(\.id) == [older.groupID])
        #expect(requested == 1, "Every batch belongs to the same background time request")
    }

    @Test(.timeLimit(.minutes(1)))
    func backgroundTimeExpiryKeepsTheSameInviteForTheNextForegroundLaunch() async throws {
        let authorDevice = GroupDeliveryTestIdentity("expiry-nearby-sender")
        let recipientDevice = GroupDeliveryTestIdentity("expiry-nearby-recipient")
        defer { authorDevice.remove(); recipientDevice.remove() }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let first = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        defer { first.stopGroupDeliverySync(); first.disconnect() }
        first.groupDeliveryClient = nil
        first.allowsNearbyGroupDelivery = true

        var expire: (@MainActor () -> Void)?
        var ended = 0
        first.beginGroupDeliveryBackgroundTime = { expiration in
            expire = expiration
            return { ended += 1 }
        }
        first.setGroupDeliveryForeground(true)
        try #require(first.createTalkGroup(name: "Delayed invitation", userIDs: [recipientDevice.personID]))
        let pending = try #require(first.groupRepository.groupDeliveries.first)
        first.setGroupDeliveryForeground(false)
        let expireFirstWindow = try #require(expire)
        expireFirstWindow()
        #expect(first.nearbyGroupDeliveryExchange == nil)
        #expect(ended == 1)
        #expect(first.groupRepository.groupDeliveries.first?.state == .pending)

        let reopened = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        defer { reopened.stopGroupDeliverySync(); recipient.stopGroupDeliverySync() }
        for model in [reopened, recipient] {
            model.groupDeliveryClient = nil
            model.allowsNearbyGroupDelivery = true
        }
        recipient.setGroupDeliveryForeground(true)
        reopened.setGroupDeliveryForeground(true)
        expireFirstWindow()  // A retired system callback cannot stop the replacement's exchange.
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            reopened.groupRepository.groupDeliveries.first?.state == .received
        }
        try #require(reopened.groupRepository.groupDeliveries.first?.state == .received)
        #expect(reopened.groupRepository.groupDeliveries.first?.id == pending.id)
        #expect(recipient.groups.map(\.id) == [pending.groupID])
    }
}
