import Foundation
import Darwin
import Network
import Testing
@testable import RTC

private final class DatagramRecording: @unchecked Sendable {
    private let lock = NSLock()
    struct Packet {
        let sender: PeerID
        let payload: Data
        let receivedAt: TimeInterval
    }

    private var values: [Packet] = []
    func append(_ peer: PeerID, _ data: Data) {
        lock.withLock {
            values.append(.init(sender: peer, payload: data, receivedAt: ProcessInfo.processInfo.systemUptime))
        }
    }
    var packets: [Packet] { lock.withLock { values } }
}

private func activeConnection(
    from sender: LocalDatagramTransport, to receiverID: PeerID, on queue: DispatchQueue
) throws -> NWConnection {
    try queue.sync {
        let outgoing = try #require(
            Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection]
        )
        return try #require(outgoing[sender.serviceName(for: receiverID)])
    }
}

private func verifyBackoffAndRecovery(
    sender: LocalDatagramTransport, receiverID: PeerID, receiverNonce: String,
    recording: DatagramRecording, queue: DispatchQueue
) async throws {
    let current = try activeConnection(from: sender, to: receiverID, on: queue)
    let betterPath = try #require(current.betterPathUpdateHandler)
    try queue.sync {
        betterPath(true)
        let candidates = try #require(
            Mirror(reflecting: sender).children.first { $0.label == "replacements" }?.value as? [String: NWConnection]
        )
        let candidate = try #require(candidates[sender.serviceName(for: receiverID)])
        let failed = try #require(candidate.stateUpdateHandler)
        failed(.failed(.posix(.ENETDOWN)))
    }
    #expect(try activeConnection(from: sender, to: receiverID, on: queue) === current)
    #expect(sender.isReady(for: receiverID), "A failed candidate must not retire the current path")

    // A new authenticated control session clears the candidate's backoff.
    sender.connect(to: receiverID, nonce: receiverNonce)
    let failed = try #require(current.stateUpdateHandler)
    queue.sync { failed(.failed(.posix(.ENETDOWN))) }
    for _ in 0..<32 { #expect(sender.send(Data([254]), to: [receiverID]).accepted.isEmpty) }
    let attempts = queue.sync {
        Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value as? [String: NWConnection]
    }
    #expect(attempts?.isEmpty == true, "Continuous audio must not turn a failed path into connection polling")
    // The next new packet may retry after backoff; none of the discarded speech returns.
    try await Task.sleep(for: .milliseconds(2100))
    #expect(sender.send(Data([253]), to: [receiverID]).accepted.isEmpty)
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(sender.send(Data([3]), to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(recording.packets.map(\.payload) == [Data([0]), Data([1]), Data([2]), Data([3])])
}

// These tests share native Bonjour/run-loop resources. Do not overlap the
// deliberate control-actor stalls and restart storms with the 50 ms latency gate.
@Suite(.serialized) struct RealtimeTransportTests {}

extension RealtimeTransportTests {
@Test func localDatagramsArriveImmediatelyWithoutReliableRecoveryOrBacklog() async throws {
    let recording = DatagramRecording()
    let senderID = PeerID(rawValue: "sender"), receiverID = PeerID(rawValue: "receiver")
    let sender = LocalDatagramTransport(
        peerID: senderID, credential: .derived(groupID: "test-group", secret: "fixture-media")
    ) { _, _ in }
    let receiver = LocalDatagramTransport(
        peerID: receiverID, credential: .derived(groupID: "test-group", secret: "fixture-media")
    ) { recording.append($0, $1) }
    try sender.start(); try receiver.start()
    defer { sender.stop(); receiver.stop() }
    #expect(sender.send(Data([255]), to: [receiverID]).accepted.isEmpty, "Unconnected audio must not become a backlog")
    for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(receiver.port)
    sender.connect(
        to: receiverID, nonce: receiver.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: port))
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sender.isReady(for: receiverID))
    var sent: [TimeInterval] = []
    for index in 0..<100 {
        let data = Data([UInt8(index)]) + Data(repeating: 0x42, count: 1999)
        sent.append(ProcessInfo.processInfo.systemUptime)
        #expect(sender.send(data, to: [receiverID]).accepted == [receiverID])
        try await Task.sleep(for: .milliseconds(5))
    }
    for _ in 0..<100 where recording.packets.count < 100 { try await Task.sleep(for: .milliseconds(5)) }
    let received = recording.packets
    #expect(received.count == 100)
    for (index, packet) in received.enumerated() {
        #expect(packet.sender == senderID)
        #expect(packet.payload == Data([UInt8(index)]) + Data(repeating: 0x42, count: 1999))
        #expect(
            packet.receivedAt - sent[index] < 0.05,
            "Local loopback media must not acquire a retransmission or batching delay")
    }
    sender.stop()
    #expect(sender.send(Data([254]), to: [receiverID]).accepted.isEmpty)
}

@Test func localDatagramsSurviveRepeatedEndpointAndSenderRestartsWithoutReplayingOldAudio() async throws {
    let recording = DatagramRecording(), group = UUID().uuidString
    let senderID = PeerID(rawValue: "restart-sender"), receiverID = PeerID(rawValue: "restart-receiver")
    let sender = LocalDatagramTransport(
        peerID: senderID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { _, _ in }
    let receiver = LocalDatagramTransport(
        peerID: receiverID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { recording.append($0, $1) }
    try receiver.start()
    defer { sender.stop(); receiver.stop() }
    for index in 0..<24 {
        if index == 12 { receiver.stop(); try receiver.start() }
        try sender.start()
        for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(5)) }
        let port = try #require(receiver.port)
        sender.connect(
            to: receiverID, nonce: receiver.serviceNonce,
            endpoint: .hostPort(host: .ipv4(.loopback), port: port))
        for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(sender.send(Data([UInt8(index)]), to: [receiverID]).accepted == [receiverID])
        for _ in 0..<100 where recording.packets.count <= index { try await Task.sleep(for: .milliseconds(5)) }
        #expect(recording.packets.count == index + 1)
        sender.stop()
        #expect(sender.send(Data([255]), to: [receiverID]).accepted.isEmpty)
    }
    #expect(recording.packets.map(\.payload) == (0..<24).map { Data([UInt8($0)]) })
}

@Test func localBonjourResolvesOnlyRegisteredPeersAndDeliversInBothDirections() async throws {
    let leftRecording = DatagramRecording(), rightRecording = DatagramRecording(), group = UUID().uuidString
    let leftID = PeerID(rawValue: "a"), rightID = PeerID(rawValue: "b")
    let left = LocalDatagramTransport(
        peerID: leftID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { leftRecording.append($0, $1) }
    let right = LocalDatagramTransport(
        peerID: rightID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { rightRecording.append($0, $1) }
    try left.start(); try right.start()
    defer { left.stop(); right.stop() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(
        !left.isReady(for: rightID) && !right.isReady(for: leftID),
        "Advertising alone must not start a second group discovery")
    left.connect(to: rightID, nonce: right.serviceNonce); right.connect(to: leftID, nonce: left.serviceNonce)
    for _ in 0..<500 where !left.isReady(for: rightID) || !right.isReady(for: leftID) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(left.isReady(for: rightID), "\(left.statistics)")
    #expect(right.isReady(for: leftID), "\(right.statistics)")
    #expect(left.send(Data([1]), to: [rightID]).accepted == [rightID])
    #expect(right.send(Data([2]), to: [leftID]).accepted == [leftID])
    for _ in 0..<100 where leftRecording.packets.isEmpty || rightRecording.packets.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(leftRecording.packets.map(\.payload) == [Data([2])])
    #expect(rightRecording.packets.map(\.payload) == [Data([1])])
    left.remove(rightID)
    #expect(!left.isReady(for: rightID))
    #expect(left.send(Data([3]), to: [rightID]).accepted.isEmpty, "Retired membership must not restart an old endpoint")
    left.connect(to: rightID, nonce: right.serviceNonce)
    for _ in 0..<500 where !left.isReady(for: rightID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(left.send(Data([4]), to: [rightID]).accepted == [rightID])
    for _ in 0..<100 where rightRecording.packets.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(rightRecording.packets.map(\.payload) == [Data([1]), Data([4])])
    try await verifyBonjourRestart(sender: left, receiver: right, receiverID: rightID, recording: rightRecording)
}

private func verifyBonjourRestart(
    sender: LocalDatagramTransport, receiver: LocalDatagramTransport, receiverID: PeerID, recording: DatagramRecording
) async throws {
    let queue = try #require(Mirror(reflecting: sender).children.first { $0.label == "queue" }?.value as? DispatchQueue)
    func outgoing() -> NWConnection? {
        queue.sync {
            (Mirror(reflecting: sender).children.first { $0.label == "outgoing" }?.value
                as? [String: NWConnection])?[sender.serviceName(for: receiverID)]
        }
    }
    let old = try #require(outgoing())
    let oldPort = receiver.port
    receiver.stop(); try receiver.start()
    for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(receiver.port != oldPort, "Exercise a peer restart with a changed UDP port")
    // A new authenticated control session re-resolves this peer.
    sender.connect(to: receiverID, nonce: receiver.serviceNonce)
    for _ in 0..<500 where outgoing() === old || !sender.isReady(for: receiverID) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(outgoing() !== old)
    #expect(sender.send(Data([5]), to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(recording.packets.map(\.payload) == [Data([1]), Data([4]), Data([5])])
    let current = try #require(outgoing())
    let failed = try #require(current.stateUpdateHandler)
    queue.sync { failed(.failed(.posix(.ENETDOWN))) }
    sender.connect(to: receiverID, nonce: receiver.serviceNonce) // Fresh authentication is new reachability evidence.
    for _ in 0..<500 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sender.isReady(for: receiverID), "New authentication must not inherit an old session's failure deadline")
}

@Test func localUDPAllowsInfrastructureFreeDiscoveryButProhibitsCellular() throws {
    let parameters = LocalDatagramTransport.parameters()
    #expect(parameters.includePeerToPeer)
    #expect(parameters.requiredInterface == nil)
    #expect(parameters.requiredInterfaceType == .other)
    #expect(parameters.prohibitedInterfaceTypes == [.cellular])
    #expect(parameters.defaultProtocolStack.transportProtocol is NWProtocolUDP.Options)
}

@Test func localUDPReplacesChangedPathsWithoutWaitingOrReplayingAudio() async throws {
    let receiverID = PeerID(rawValue: "path-receiver"), senderID = PeerID(rawValue: "path-sender")
    let recording = DatagramRecording()
    let sender = LocalDatagramTransport(
        peerID: senderID, credential: .derived(groupID: UUID().uuidString, secret: "fixture-media")
    ) { _, _ in }
    let receiver = LocalDatagramTransport(
        peerID: receiverID, credential: .derived(groupID: UUID().uuidString, secret: "fixture-media")
    ) { recording.append($0, $1) }
    try sender.start(); try receiver.start()
    defer { sender.stop(); receiver.stop() }
    for _ in 0..<100 where receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    let port = try #require(receiver.port)
    sender.connect(
        to: receiverID, nonce: receiver.serviceNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: port))
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    // Exercise the real native callbacks on their owner queue without changing
    // the host's Wi-Fi settings or introducing a production test-only path.
    let queue = try #require(Mirror(reflecting: sender).children.first { $0.label == "queue" }?.value as? DispatchQueue)
    var previous = try activeConnection(from: sender, to: receiverID, on: queue)
    let betterPath = try #require(previous.betterPathUpdateHandler)
    let viability = try #require(previous.viabilityUpdateHandler)
    #expect(sender.send(Data([0]), to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
    queue.sync { betterPath(true); betterPath(true) }
    // While the replacement resolves, a still-usable current path remains ready.
    #expect(sender.isReady(for: receiverID))
    for _ in 0..<100 where try activeConnection(from: sender, to: receiverID, on: queue) === previous {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try activeConnection(from: sender, to: receiverID, on: queue) !== previous)
    #expect(sender.send(Data([1]), to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    // Late callbacks from the retired path cannot clear the new path's readiness.
    queue.sync { viability(false); betterPath(true) }
    #expect(sender.isReady(for: receiverID))
    previous = try activeConnection(from: sender, to: receiverID, on: queue)
    let lostPath = try #require(previous.viabilityUpdateHandler)
    queue.sync { lostPath(false) }
    for _ in 0..<100 where try activeConnection(from: sender, to: receiverID, on: queue) === previous {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(try activeConnection(from: sender, to: receiverID, on: queue) !== previous)
    #expect(sender.send(Data([2]), to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(recording.packets.map(\.payload) == [Data([0]), Data([1]), Data([2])])
    try await verifyBackoffAndRecovery(
        sender: sender, receiverID: receiverID, receiverNonce: receiver.serviceNonce, recording: recording, queue: queue
    )
    sender.stop()
    queue.sync { lostPath(false) }
    #expect(!sender.isReady(for: receiverID))
    #expect(sender.send(Data([255]), to: [receiverID]).accepted.isEmpty)
}

@Test func anAcceptedUDPDatagramDoesNotProveTheRemoteMediaPath() async throws {
    // A bound UDP socket deliberately never reads or responds. The kernel still accepts sends.
    let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    try #require(socket >= 0)
    defer { Darwin.close(socket) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bound == 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
    }
    try #require(named == 0)
    let port = try #require(NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)))
    let peer = PeerID(rawValue: "blackhole-target")
    let sender = LocalDatagramTransport(
        peerID: .init(rawValue: "blackhole-sender"),
        credential: .derived(groupID: "blackhole-test", secret: "fixture-media")
    ) { _, _ in }
    try sender.start(); defer { sender.stop() }
    sender.connect(to: peer, nonce: "blackhole-listener", endpoint: .hostPort(host: .ipv4(.loopback), port: port))
    var accepted = false
    for _ in 0..<100 {
        accepted = sender.send(Data([0x71]), to: [peer]).accepted.contains(peer)
        if accepted { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(accepted, "The sender must actually reach UDP send acceptance before testing reachability")
    #expect(
        !sender.hasRecentMediaReceipt(for: peer),
        "A peer that has never answered cannot suppress a working alternate media route")
}

@Test func actualMediaArrivesWithoutWaitingAndItsReceiptExpires() async throws {
    let group = UUID().uuidString, senderID = PeerID(rawValue: "receipt-a"), receiverID = PeerID(rawValue: "receipt-b")
    let recording = DatagramRecording()
    let sender = LocalDatagramTransport(
        peerID: senderID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { _, _ in }
    let receiver = LocalDatagramTransport(
        peerID: receiverID, credential: .derived(groupID: group, secret: "fixture-media")
    ) { recording.append($0, $1) }
    try sender.start(); try receiver.start(); defer { sender.stop(); receiver.stop() }
    for _ in 0..<100 where sender.port == nil || receiver.port == nil { try await Task.sleep(for: .milliseconds(10)) }
    sender.connect(
        to: receiverID, nonce: receiver.serviceNonce,
        endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(receiver.port)))
    receiver.connect(
        to: senderID, nonce: sender.serviceNonce,
        endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(sender.port)))
    for _ in 0..<100 where !sender.isReady(for: receiverID) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!sender.hasRecentMediaReceipt(for: receiverID))
    let first = Data(repeating: 0x71, count: 256), started = ProcessInfo.processInfo.systemUptime
    #expect(sender.send(first, to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where recording.packets.isEmpty || !sender.hasRecentMediaReceipt(for: receiverID) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(recording.packets.first?.payload == first)
    #expect((recording.packets.first?.receivedAt ?? .infinity) - started < 0.05)
    #expect(sender.hasRecentMediaReceipt(for: receiverID))
    try await Task.sleep(for: .milliseconds(1600))
    #expect(sender.isReady(for: receiverID), "OS readiness and recent media delivery are different facts")
    #expect(!sender.hasRecentMediaReceipt(for: receiverID))
    let second = Data(repeating: 0x72, count: 256)
    #expect(sender.send(second, to: [receiverID]).accepted == [receiverID])
    for _ in 0..<100 where !sender.hasRecentMediaReceipt(for: receiverID) {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(sender.hasRecentMediaReceipt(for: receiverID))
    #expect(recording.packets.map(\.payload) == [first, second])
}

}
