import Foundation
import RideComRTC
import Synchronization

private final class Completion<Value: Sendable>: Sendable {
    let continuation: CheckedContinuation<Value, Never>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }
}

private final class ConnectionRecording: Sendable {
    let iceConnected = Mutex(false)
    let changes = Mutex(0)
    let packets = Mutex<[Data]>([])
}

private func observe(
    peer: OpaquePointer, channels: [OpaquePointer], recording: ConnectionRecording
) -> Unmanaged<ConnectionRecording> {
    let context = Unmanaged.passRetained(recording)
    RideComRTCPeerObserveIce(peer, context.toOpaque()) { pointer, state in
        guard let pointer, state == RideComRTCIceConnected else { return }
        let recording = Unmanaged<ConnectionRecording>.fromOpaque(pointer).takeUnretainedValue()
        recording.iceConnected.withLock { $0 = true }
    }
    for channel in channels {
        RideComRTCChannelObserve(
            channel, context.toOpaque(),
            { pointer in
                guard let pointer else { return }
                let recording = Unmanaged<ConnectionRecording>.fromOpaque(pointer).takeUnretainedValue()
                recording.changes.withLock { $0 += 1 }
            },
            { pointer, bytes, count in
                guard let pointer, let bytes else { return }
                let recording = Unmanaged<ConnectionRecording>.fromOpaque(pointer).takeUnretainedValue()
                let packet = Data(bytes: bytes, count: count)
                recording.packets.withLock { $0.append(packet) }
            }
        )
    }
    return context
}

private func stopObserving(
    peer: OpaquePointer, channels: [OpaquePointer], context: Unmanaged<ConnectionRecording>
) {
    RideComRTCPeerObserveIce(peer, nil, nil)
    for channel in channels {
        RideComRTCChannelObserve(channel, nil, nil, nil)
    }
    context.release()
}

private func send(_ packet: Data, on channel: OpaquePointer) -> Bool {
    packet.withUnsafeBytes { buffer in
        RideComRTCChannelSend(channel, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
    }
}

private func ipv4LoopbackSDP(_ sdp: String) -> String {
    var loopbackCandidates = 0
    let lines = sdp.split(whereSeparator: \.isNewline).filter { line in
        guard line.hasPrefix("a=candidate:") else { return true }
        let fields = line.split(separator: " ")
        guard fields.count >= 5, fields[4] == "127.0.0.1" else { return false }
        loopbackCandidates += 1
        return true
    }
    precondition(loopbackCandidates > 0, "SDP did not contain a local loopback candidate")
    return lines.joined(separator: "\r\n") + "\r\n"
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

@MainActor
private func waitForDescription(
    _ operation: (UnsafeMutableRawPointer, RideComRTCDescriptionCompletion) -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        let context = Unmanaged.passRetained(Completion(continuation)).toOpaque()
        operation(context) { @Sendable rawContext, success in
            guard let rawContext else { return }
            let result = Unmanaged<Completion<Bool>>.fromOpaque(rawContext).takeRetainedValue()
            result.continuation.resume(returning: success)
        }
    }
}

@MainActor
private func readIceRoundTripTime(_ peer: OpaquePointer) async -> Double? {
    await withCheckedContinuation { continuation in
        let context = Unmanaged.passRetained(Completion(continuation)).toOpaque()
        RideComRTCPeerGetIcePath(peer, context) { @Sendable rawContext, available, seconds, _ in
            guard let rawContext else { return }
            let result = Unmanaged<Completion<Double?>>.fromOpaque(rawContext).takeRetainedValue()
            result.continuation.resume(returning: available ? seconds : nil)
        }
    }
}

@MainActor
private func prepareLocalDescription(_ peer: OpaquePointer) async -> String {
    let applied = await waitForDescription { context, completion in
        RideComRTCPeerSetLocalDescription(peer, context, completion)
    }
    precondition(applied)
    for _ in 0..<100 {
        if RideComRTCPeerHasGatheredCandidates(peer) { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    guard let description = RideComRTCPeerCopyLocalDescription(peer) else {
        preconditionFailure("Could not copy local SDP")
    }
    defer { RideComRTCDescriptionRelease(description) }
    let sdp = String(cString: description)
    let mediaLines = sdp.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("m=") }
    precondition(!mediaLines.isEmpty && mediaLines.allSatisfy { $0.hasPrefix("m=application ") })
    return sdp
}

@MainActor
private func applyRemoteDescription(
    _ peer: OpaquePointer, kind: RideComRTCDescriptionKind, sdp: String
) async -> Bool {
    await waitForDescription { context, completion in
        RideComRTCPeerSetRemoteDescription(peer, kind, sdp, context, completion)
    }
}

@MainActor
private func checkClosingDuringNegotiation(_ factory: OpaquePointer) async {
    guard
        let peer = RideComRTCPeerCreate(factory, false),
        let channel = RideComRTCChannelCreate(peer, "control", 0, true)
    else {
        preconditionFailure("Could not create a peer for shutdown")
    }
    defer { RideComRTCChannelRelease(channel) }
    _ = await waitForDescription { context, completion in
        RideComRTCPeerSetLocalDescription(peer, context, completion)
        RideComRTCPeerRelease(peer)
    }
    precondition(RideComRTCChannelGetState(channel) == RideComRTCChannelClosed)
}

@MainActor
private func exchangeDescriptions(sender: OpaquePointer, receiver: OpaquePointer) async {
    precondition(RideComRTCPeerCopyLocalDescription(sender) == nil)
    let offer = await ipv4LoopbackSDP(prepareLocalDescription(sender))
    for invalid in ["", "v=0\r\n", offer + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"] {
        let accepted = await applyRemoteDescription(receiver, kind: RideComRTCDescriptionOffer, sdp: invalid)
        precondition(!accepted)
    }
    let offerAccepted = await applyRemoteDescription(receiver, kind: RideComRTCDescriptionOffer, sdp: offer)
    precondition(offerAccepted)

    let answer = await ipv4LoopbackSDP(prepareLocalDescription(receiver))
    let videoAccepted = await applyRemoteDescription(
        sender, kind: RideComRTCDescriptionAnswer, sdp: answer + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
    )
    precondition(!videoAccepted)
    let answerAccepted = await applyRemoteDescription(sender, kind: RideComRTCDescriptionAnswer, sdp: answer)
    precondition(answerAccepted)
}

private func checkIceServerUpdate(on peer: OpaquePointer) {
    func setServer(_ url: String) -> Bool {
        url.withCString { pointer in
            var server = RideComRTCIceServer(url: pointer, username: nil, password: nil)
            return RideComRTCPeerSetIceServers(peer, &server, 1)
        }
    }

    precondition(setServer("stun:127.0.0.1:3478"))
    let turnAccepted = "turn:127.0.0.1:3478?transport=udp".withCString { url in
        "loopback-test".withCString { credential in
            var server = RideComRTCIceServer(url: url, username: credential, password: credential)
            return RideComRTCPeerSetIceServers(peer, &server, 1)
        }
    }
    precondition(turnAccepted)
    precondition(!setServer("turns:127.0.0.1:5349"))
    precondition(!setServer("turn:127.0.0.1:3478?transport=tcp"))
    precondition(!setServer("stun:"))
    precondition(!RideComRTCPeerSetIceServers(peer, nil, 0))
}

@MainActor
private func checkPacketTransfer(
    sender: OpaquePointer, senderChannels: [OpaquePointer], receiverChannels: [OpaquePointer],
    senderRecording: ConnectionRecording, receiverRecording: ConnectionRecording
) async {
    let allOpened = await waitUntil {
        (senderChannels + receiverChannels).allSatisfy { RideComRTCChannelGetState($0) == RideComRTCChannelOpen }
    }
    precondition(allOpened, "DataChannels did not open over loopback")
    let gotChanges = await waitUntil {
        senderRecording.changes.withLock { $0 > 0 } && receiverRecording.changes.withLock { $0 > 0 }
    }
    precondition(gotChanges)
    let sawIceConnected = await waitUntil {
        senderRecording.iceConnected.withLock { $0 } && receiverRecording.iceConnected.withLock { $0 }
    }
    precondition(sawIceConnected)
    checkIceServerUpdate(on: sender)
    precondition(!send(Data(repeating: 0, count: 48 * 1024 + 1), on: senderChannels[0]))

    let sentBySender = [Data([0, 1, 2]), Data([3, 4, 5])]
    let sentByReceiver = [Data([6, 7, 8]), Data([9, 10, 11])]
    for (channel, packet) in zip(senderChannels, sentBySender) {
        precondition(send(packet, on: channel))
    }
    for (channel, packet) in zip(receiverChannels, sentByReceiver) {
        precondition(send(packet, on: channel))
    }
    let receivedPackets = await waitUntil {
        senderRecording.packets.withLock { $0.count == sentByReceiver.count && Set($0) == Set(sentByReceiver) }
            && receiverRecording.packets.withLock { $0.count == sentBySender.count && Set($0) == Set(sentBySender) }
    }
    precondition(receivedPackets, "Both channel types must deliver binary data in both directions")
}

@MainActor
private func checkNegotiation() async {
    guard
        let factory = RideComRTCFactoryCreate(true),
        let sender = RideComRTCPeerCreate(factory, false),
        let receiver = RideComRTCPeerCreate(factory, false),
        let senderControl = RideComRTCChannelCreate(sender, "control", 0, true),
        let senderAudio = RideComRTCChannelCreate(sender, "audio", 1, false),
        let receiverControl = RideComRTCChannelCreate(receiver, "control", 0, true),
        let receiverAudio = RideComRTCChannelCreate(receiver, "audio", 1, false)
    else {
        preconditionFailure("Could not create two peers with matching channels")
    }
    let senderChannels = [senderControl, senderAudio]
    let receiverChannels = [receiverControl, receiverAudio]
    defer {
        (senderChannels + receiverChannels).forEach(RideComRTCChannelRelease)
        RideComRTCPeerRelease(sender)
        RideComRTCPeerRelease(receiver)
        RideComRTCFactoryRelease(factory)
    }
    let senderRecording = ConnectionRecording()
    let receiverRecording = ConnectionRecording()
    let senderContext = observe(peer: sender, channels: senderChannels, recording: senderRecording)
    let receiverContext = observe(peer: receiver, channels: receiverChannels, recording: receiverRecording)
    defer {
        stopObserving(peer: sender, channels: senderChannels, context: senderContext)
        stopObserving(peer: receiver, channels: receiverChannels, context: receiverContext)
    }

    precondition(RideComRTCChannelBufferedBytes(senderControl) == 0)
    precondition(!send(Data([0]), on: senderControl))
    let before = await readIceRoundTripTime(sender)
    precondition(before == nil)
    await exchangeDescriptions(sender: sender, receiver: receiver)
    await checkPacketTransfer(
        sender: sender, senderChannels: senderChannels, receiverChannels: receiverChannels,
        senderRecording: senderRecording, receiverRecording: receiverRecording
    )
    let after = await readIceRoundTripTime(sender)
    precondition(after.map { $0.isFinite && $0 >= 0 } == true)
    await checkClosingDuringNegotiation(factory)
}

await checkNegotiation()
print("Both negotiated channel types transferred binary data in both directions")
