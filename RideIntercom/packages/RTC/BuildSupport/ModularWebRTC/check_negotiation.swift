import RideComRTC

private final class DescriptionCompletion: Sendable {
    let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }
}

@MainActor
private func waitForDescription(
    _ operation: (UnsafeMutableRawPointer, RideComRTCDescriptionCompletion) -> Void
) async -> Bool {
    await withCheckedContinuation { continuation in
        let context = Unmanaged.passRetained(DescriptionCompletion(continuation)).toOpaque()
        operation(context) { rawContext, success in
            guard let rawContext else { return }
            let result = Unmanaged<DescriptionCompletion>.fromOpaque(rawContext).takeRetainedValue()
            result.continuation.resume(returning: success)
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
        let peer = RideComRTCPeerCreate(factory),
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
private func checkNegotiation() async {
    guard
        let factory = RideComRTCFactoryCreate(),
        let sender = RideComRTCPeerCreate(factory),
        let receiver = RideComRTCPeerCreate(factory),
        let senderChannel = RideComRTCChannelCreate(sender, "control", 0, true),
        let receiverChannel = RideComRTCChannelCreate(receiver, "control", 0, true)
    else {
        preconditionFailure("Could not create two peers with matching channels")
    }
    defer {
        RideComRTCChannelRelease(senderChannel)
        RideComRTCChannelRelease(receiverChannel)
        RideComRTCPeerRelease(sender)
        RideComRTCPeerRelease(receiver)
        RideComRTCFactoryRelease(factory)
    }

    precondition(RideComRTCPeerCopyLocalDescription(sender) == nil)
    let offer = await prepareLocalDescription(sender)
    for invalid in ["", "v=0\r\n", offer + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"] {
        let accepted = await applyRemoteDescription(receiver, kind: RideComRTCDescriptionOffer, sdp: invalid)
        precondition(!accepted)
    }
    let offerAccepted = await applyRemoteDescription(receiver, kind: RideComRTCDescriptionOffer, sdp: offer)
    precondition(offerAccepted)

    let answer = await prepareLocalDescription(receiver)
    let videoAccepted = await applyRemoteDescription(
        sender, kind: RideComRTCDescriptionAnswer, sdp: answer + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
    )
    precondition(!videoAccepted)
    let answerAccepted = await applyRemoteDescription(sender, kind: RideComRTCDescriptionAnswer, sdp: answer)
    precondition(answerAccepted)
    await checkClosingDuringNegotiation(factory)
}

await checkNegotiation()
print("Data-only offer and answer accepted after rejected media descriptions")
