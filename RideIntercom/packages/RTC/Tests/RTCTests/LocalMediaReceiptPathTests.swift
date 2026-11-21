import Foundation
import Network
import Testing
import RTCTestSupport
@testable import RTC

private final class MediaRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    var packets: [Data] { lock.withLock { values } }
}

private func waitForMedia(_ condition: () -> Bool) async throws {
    for _ in 0..<250 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

extension RealtimeTransportTests {
    @Test func aDelayedReadyCallbackCannotSendOrProveACancelledNativeFlow() async throws {
        let senderID = PeerID(rawValue: "cancelled-a"), receiverID = PeerID(rawValue: "cancelled-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "cancelled-fixture")
        let sender = LocalDatagramTransport(peerID: senderID, credential: credential) { _, _ in }
        let receiver = LocalDatagramTransport(peerID: receiverID, credential: credential) { _, _ in }
        try sender.start(); try receiver.start(); defer { sender.stop(); receiver.stop() }
        try await waitForMedia { sender.port != nil && receiver.port != nil }
        sender.connect(
            to: receiverID, nonce: receiver.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(receiver.port)))
        receiver.connect(
            to: senderID, nonce: sender.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(sender.port)))
        try await waitForMedia { sender.isReady(for: receiverID) }
        _ = sender.send(Data(repeating: 1, count: 256), to: [receiverID])
        try await waitForMedia { sender.hasRecentMediaReceipt(for: receiverID) }
        let connection = try #require(sender.synchronized {
                (Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value
                    as? [String: NWConnection])?[sender.serviceName(for: receiverID)]
        })
        let readyCallback = try #require(connection.stateUpdateHandler)
        // Deliver the captured ready event after the native flow has changed.
        // Keeping the cancellation callback out of this fixture exposes the
        // interval before the owner's queued state update catches up.
        sender.synchronized { connection.stateUpdateHandler = nil; connection.cancel() }
        try await waitForMedia { if case .cancelled = connection.state { return true }; return false }
        sender.synchronized { readyCallback(.ready) }
        #expect(!sender.hasRecentMediaReceipt(for: receiverID))
        let result = sender.send(Data(repeating: 2, count: 256), to: [receiverID])
        #expect(result.accepted.isEmpty && result.verified.isEmpty)
    }

    @Test func acceptedMediaLosesItsProofAcrossABlackholeAndRecoversWithoutReplay() async throws {
        let senderID = PeerID(rawValue: "blackhole-a"), receiverID = PeerID(rawValue: "blackhole-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "receipt-fixture")
        let record = MediaRecording()
        let sender = LocalDatagramTransport(peerID: senderID, credential: credential) { _, _ in }
        let receiver = LocalDatagramTransport(peerID: receiverID, credential: credential) { _, data in
            record.append(data)
        }
        try sender.start(); try receiver.start(); defer { sender.stop(); receiver.stop() }
        try await waitForMedia { sender.port != nil && receiver.port != nil }
        let proxy = try MediaBlackhole(target: #require(receiver.port)); defer { proxy.stop() }
        sender.connect(
            to: receiverID, nonce: receiver.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port))
        receiver.connect(
            to: senderID, nonce: sender.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(sender.port)))
        try await waitForMedia { sender.isReady(for: receiverID) }
        let first = sender.send(Data(repeating: 0x71, count: 256), to: [receiverID])
        #expect(first.accepted == [receiverID] && first.verified.isEmpty)
        try await waitForMedia { sender.hasRecentMediaReceipt(for: receiverID) }
        proxy.setBlocked(true)
        // A new control authentication of the same peer must keep the explicit media path.
        sender.connect(to: receiverID, nonce: receiver.serviceNonce)
        try await waitForMedia { sender.isReady(for: receiverID) }
        for value in 1...90 {
            let result = sender.send(Data(repeating: UInt8(value), count: 256), to: [receiverID])
            #expect(result.accepted == [receiverID])
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sender.isReady(for: receiverID) && !sender.hasRecentMediaReceipt(for: receiverID))
        #expect(sender.send(Data(repeating: 0x72, count: 256), to: [receiverID]).verified.isEmpty)
        // Settle the last OS-accepted datagram at the drop boundary before
        // reopening it; an in-flight packet is not an application replay.
        try await waitForMedia { proxy.droppedCount >= 91 }
        #expect(record.packets == [Data(repeating: 0x71, count: 256)])
        proxy.setBlocked(false)
        for value in 208...228 where !sender.hasRecentMediaReceipt(for: receiverID) {
            _ = sender.send(Data(repeating: UInt8(value), count: 256), to: [receiverID])
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sender.hasRecentMediaReceipt(for: receiverID))
        #expect(record.packets.dropFirst().allSatisfy { ($0.first ?? 0) >= 208 })
        #expect(sender.send(Data(repeating: 240, count: 256), to: [receiverID]).verified == [receiverID])
    }

    @Test func betterPathKeepsAProvenFlowUntilTheCandidateReceivesRealMedia() async throws {
        let senderID = PeerID(rawValue: "path-a"), receiverID = PeerID(rawValue: "path-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "path-fixture")
        let record = MediaRecording()
        let sender = LocalDatagramTransport(peerID: senderID, credential: credential) { _, _ in }
        let receiver = LocalDatagramTransport(peerID: receiverID, credential: credential) { _, data in
            record.append(data)
        }
        try sender.start(); try receiver.start(); defer { sender.stop(); receiver.stop() }
        try await waitForMedia { sender.port != nil && receiver.port != nil }
        sender.connect(
            to: receiverID, nonce: receiver.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(receiver.port)))
        receiver.connect(
            to: senderID, nonce: sender.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(sender.port)))
        try await waitForMedia { sender.isReady(for: receiverID) }
        _ = sender.send(Data(repeating: 1, count: 256), to: [receiverID])
        try await waitForMedia { sender.hasRecentMediaReceipt(for: receiverID) }
        let queue = try #require(
            Mirror(reflecting: sender).children.first { $0.label == "queue" }?.value as? DispatchQueue)
        let name = sender.serviceName(for: receiverID)
        func current() -> NWConnection? {
            queue.sync {
                (Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value
                    as? [String: NWConnection])?[name]
            }
        }
        let old = try #require(current()), better = try #require(old.betterPathUpdateHandler)
        let stale = try #require(old.viabilityUpdateHandler)
        queue.sync { better(true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(current() === old, "OS ready alone must not replace a proven flow")
        #expect(sender.send(Data(repeating: 2, count: 256), to: [receiverID]).verified == [receiverID])
        try await waitForMedia { current() !== old }
        #expect(sender.hasRecentMediaReceipt(for: receiverID))
        queue.sync { stale(false); better(true) }
        #expect(sender.hasRecentMediaReceipt(for: receiverID))
        #expect(record.packets.contains(Data(repeating: 2, count: 256)))
        sender.stop()
        #expect(!sender.hasRecentMediaReceipt(for: receiverID))
    }
}
