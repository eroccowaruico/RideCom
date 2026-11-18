import Darwin
import Foundation
import Network
import Testing
@testable import RTC

private final class MediaRecording: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []
    func append(_ data: Data) { lock.withLock { values.append(data) } }
    var packets: [Data] { lock.withLock { values } }
}

/// An owned loopback NAT: media can be dropped while reverse receipts keep
/// forwarding. Neither the host interface nor the real peer is disconnected.
private final class MediaBlackhole: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rtc.tests.media-blackhole")
    private let key = DispatchSpecificKey<Bool>()
    private let front: Int32, back: Int32
    private var sources: [DispatchSourceRead] = []
    private var client: sockaddr_in?
    private var blocked = false
    private var dropped = 0
    let port: NWEndpoint.Port
    init(target: NWEndpoint.Port) throws {
        let front = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        let back = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        self.front = front; self.back = back
        guard front >= 0, back >= 0 else {
            if front >= 0 { Darwin.close(front) }; if back >= 0 { Darwin.close(back) }
            throw POSIXError(.EMFILE)
        }
        var address = Self.address(port: 0)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(front, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { Darwin.close(front); Darwin.close(back); throw POSIXError(.EADDRINUSE) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(front, $0, &size) }
        }
        guard named == 0, let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)) else {
            Darwin.close(front); Darwin.close(back); throw POSIXError(.EINVAL)
        }
        self.port = port
        queue.setSpecific(key: key, value: true)
        for fd in [front, back] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        let destination = Self.address(port: target.rawValue)
        for fd in [front, back] {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setCancelHandler { Darwin.close(fd) }
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    var sender = Self.address(port: 0), size = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let count = withUnsafeMutablePointer(to: &sender) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &size) }
                    }
                    guard count > 0 else { break }
                    let bytes = Data(buffer.prefix(count))
                    if fd == self.front {
                        self.client = sender
                        if !self.blocked { Self.send(bytes, fd: self.back, to: destination) }
                        else { self.dropped += 1 }
                    } else if let client = self.client { Self.send(bytes, fd: self.front, to: client) }
                }
            }
            sources.append(source); source.resume()
        }
    }
    deinit { stop() }
    var droppedCount: Int { queue.sync { dropped } }
    func setBlocked(_ blocked: Bool) { queue.sync { self.blocked = blocked } }
    func stop() {
        let stop = { self.sources.forEach { $0.cancel() }; self.sources.removeAll() }
        if DispatchQueue.getSpecific(key: key) == true { stop() } else { queue.sync(execute: stop) }
    }
    private static func address(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian; return address
    }
    private static func send(_ bytes: Data, fd: Int32, to destination: sockaddr_in) {
        var destination = destination
        bytes.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
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
