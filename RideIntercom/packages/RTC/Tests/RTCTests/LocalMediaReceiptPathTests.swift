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
        let aID = PeerID(rawValue: "cancelled-a"), bID = PeerID(rawValue: "cancelled-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "cancelled-fixture")
        let a = LocalDatagramTransport(peerID: aID, credential: credential) { _, _ in }
        let b = LocalDatagramTransport(peerID: bID, credential: credential) { _, _ in }
        try a.start(); try b.start(); defer { a.stop(); b.stop() }
        try await waitForMedia { a.port != nil && b.port != nil }
        a.connect(to: bID, nonce: b.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(b.port)))
        b.connect(to: aID, nonce: a.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(a.port)))
        try await waitForMedia { a.isReady(for: bID) }
        _ = a.send(Data(repeating: 1, count: 256), to: [bID])
        try await waitForMedia { a.hasRecentMediaReceipt(for: bID) }
        let connection = try #require(a.synchronized {
            (Mirror(reflecting: a).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection])?[a.serviceName(for: bID)]
        })
        let readyCallback = try #require(connection.stateUpdateHandler)
        // Deliver the captured ready event after the native flow has changed.
        // Keeping the cancellation callback out of this fixture exposes the
        // interval before the owner's queued state update catches up.
        a.synchronized { connection.stateUpdateHandler = nil; connection.cancel() }
        try await waitForMedia { if case .cancelled = connection.state { return true }; return false }
        a.synchronized { readyCallback(.ready) }
        #expect(!a.hasRecentMediaReceipt(for: bID))
        let result = a.send(Data(repeating: 2, count: 256), to: [bID])
        #expect(result.accepted.isEmpty && result.verified.isEmpty)
    }

    @Test func acceptedMediaLosesItsProofAcrossABlackholeAndRecoversWithoutReplay() async throws {
        let aID = PeerID(rawValue: "blackhole-a"), bID = PeerID(rawValue: "blackhole-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "receipt-fixture")
        let record = MediaRecording()
        let a = LocalDatagramTransport(peerID: aID, credential: credential) { _, _ in }
        let b = LocalDatagramTransport(peerID: bID, credential: credential) { _, data in record.append(data) }
        try a.start(); try b.start(); defer { a.stop(); b.stop() }
        try await waitForMedia { a.port != nil && b.port != nil }
        let proxy = try MediaBlackhole(target: #require(b.port)); defer { proxy.stop() }
        a.connect(to: bID, nonce: b.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port))
        b.connect(to: aID, nonce: a.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(a.port)))
        try await waitForMedia { a.isReady(for: bID) }
        let first = a.send(Data(repeating: 0x71, count: 256), to: [bID])
        #expect(first.accepted == [bID] && first.verified.isEmpty)
        try await waitForMedia { a.hasRecentMediaReceipt(for: bID) }
        proxy.setBlocked(true)
        for value in 1...90 {
            let result = a.send(Data(repeating: UInt8(value), count: 256), to: [bID])
            #expect(result.accepted == [bID])
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(a.isReady(for: bID) && !a.hasRecentMediaReceipt(for: bID))
        #expect(a.send(Data(repeating: 0x72, count: 256), to: [bID]).verified.isEmpty)
        // Settle the last OS-accepted datagram at the drop boundary before
        // reopening it; an in-flight packet is not an application replay.
        try await waitForMedia { proxy.droppedCount >= 91 }
        #expect(record.packets == [Data(repeating: 0x71, count: 256)])
        proxy.setBlocked(false)
        for value in 208...228 where !a.hasRecentMediaReceipt(for: bID) {
            _ = a.send(Data(repeating: UInt8(value), count: 256), to: [bID])
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(a.hasRecentMediaReceipt(for: bID))
        #expect(record.packets.dropFirst().allSatisfy { ($0.first ?? 0) >= 208 })
        #expect(a.send(Data(repeating: 240, count: 256), to: [bID]).verified == [bID])
    }

    @Test func betterPathKeepsAProvenFlowUntilTheCandidateReceivesRealMedia() async throws {
        let aID = PeerID(rawValue: "path-a"), bID = PeerID(rawValue: "path-b")
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "path-fixture")
        let record = MediaRecording()
        let a = LocalDatagramTransport(peerID: aID, credential: credential) { _, _ in }
        let b = LocalDatagramTransport(peerID: bID, credential: credential) { _, data in record.append(data) }
        try a.start(); try b.start(); defer { a.stop(); b.stop() }
        try await waitForMedia { a.port != nil && b.port != nil }
        a.connect(to: bID, nonce: b.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(b.port)))
        b.connect(to: aID, nonce: a.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(a.port)))
        try await waitForMedia { a.isReady(for: bID) }
        _ = a.send(Data(repeating: 1, count: 256), to: [bID])
        try await waitForMedia { a.hasRecentMediaReceipt(for: bID) }
        let queue = try #require(Mirror(reflecting: a).children.first { $0.label == "queue" }?.value as? DispatchQueue)
        let name = a.serviceName(for: bID)
        func current() -> NWConnection? {
            queue.sync { (Mirror(reflecting: a).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection])?[name] }
        }
        let old = try #require(current()), better = try #require(old.betterPathUpdateHandler)
        let stale = try #require(old.viabilityUpdateHandler)
        queue.sync { better(true) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(current() === old, "OS ready alone must not replace a proven flow")
        #expect(a.send(Data(repeating: 2, count: 256), to: [bID]).verified == [bID])
        try await waitForMedia { current() !== old }
        #expect(a.hasRecentMediaReceipt(for: bID))
        queue.sync { stale(false); better(true) }
        #expect(a.hasRecentMediaReceipt(for: bID))
        #expect(record.packets.contains(Data(repeating: 2, count: 256)))
        a.stop()
        #expect(!a.hasRecentMediaReceipt(for: bID))
    }
}
