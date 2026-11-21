import Foundation
import Testing
import RTC
@testable import RTCNativeWebRTC
@preconcurrency import WebRTC

func loopbackEngine() -> WebRTCNativeEngine {
    let factory = RTCPeerConnectionFactory(), options = RTCPeerConnectionFactoryOptions()
    options.ignoreLoopbackNetworkAdapter = false
    factory.setOptions(options)
    return WebRTCNativeEngine(iceServers: [], factory: factory)
}

@Test func nativeSDPUsesPacketTransportAndReportsRejectedAnswers() async throws {
    let engine = WebRTCNativeEngine(iceServers: [])
    let peer = PeerDescriptor(id: .init(rawValue: "native-check"), displayName: "Native")
    #expect(engine.isAvailable)
    for _ in 0..<2 {
        await engine.prepareTransport()
        await engine.createPeerConnection(for: peer)
        let offer = try #require(await engine.makeOffer(for: peer.id))
        #expect(!offer.sdp.contains("m=audio"))
        #expect(offer.sdp.contains("a=sctp-port:5000"))
        #expect(!offer.sdp.contains("m=video"))
        #expect(offer.sdp.contains("m=application"))
        #expect(await !engine.acceptAnswer(.init(kind: .answer, sdp: "invalid"), from: peer.id))
        await engine.close(); await engine.close()
        #expect(await engine.makeOffer(for: peer.id) == nil)
    }
}

private actor PacketRecorder {
    var messages: [ApplicationDataMessage] = []
    var states: [RouteConnectionState] = []
    func record(_ event: WebRTCEngineEvent) {
        if case .connectionStateChanged(let state) = event { states.append(state) }
        if case .receivedApplicationData(let data) = event { messages.append(data.message) }
    }
}

@Test(.timeLimit(.minutes(1))) func nativePairTransfersEncodedAudioInBothDirectionsWithoutMicrophone() async throws {
    let offerer = loopbackEngine(), answerer = loopbackEngine()
    let peer = PeerDescriptor(id: .init(rawValue: "connection"), displayName: "Connection")
    let offererRecord = PacketRecorder(), answererRecord = PacketRecorder()
    let offererEvents = offerer.events, answererEvents = answerer.events
    let offererTask = Task { for await event in offererEvents { await offererRecord.record(event) } }
    let answererTask = Task { for await event in answererEvents { await answererRecord.record(event) } }
    defer { offererTask.cancel(); answererTask.cancel() }
    await preparePair(offerer: offerer, answerer: answerer, peer: peer)
    let offer = try #require(await offerer.makeOffer(for: peer.id))
    let answer = try #require(await answerer.acceptOffer(offer, from: peer.id))
    #expect(await offerer.acceptAnswer(answer, from: peer.id))
    let audio = RTCAudioPacket(
        sequenceNumber: 1, codec: .pcm16,
        format: .init(sampleRate: 16000, channelCount: 1),
        payload: Data(repeating: 42, count: 640)
    )
    let message = ApplicationDataMessage(
        namespace: "encoded-audio", payload: try JSONEncoder().encode(audio), delivery: .unreliable
    )
    let control = ApplicationDataMessage(namespace: "control", payload: Data([1]), delivery: .reliable)
    var offererAccepted = false, answererAccepted = false
    for _ in 0..<200 {
        await offerer.sendApplicationData(control, to: peer.id)
        await answerer.sendApplicationData(control, to: peer.id)
        let offererSent = await offerer.sendApplicationData(message, to: peer.id)
        let answererSent = await answerer.sendApplicationData(message, to: peer.id)
        offererAccepted = offererAccepted || offererSent == true
        answererAccepted = answererAccepted || answererSent == true
        let offererMessages = await offererRecord.messages, answererMessages = await answererRecord.messages
        let offererReady = offererMessages.contains(message) && offererMessages.contains(control)
        let answererReady = answererMessages.contains(message) && answererMessages.contains(control)
        if offererReady && answererReady { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let offererStates = await offererRecord.states, answererStates = await answererRecord.states
    #expect(offererAccepted && answererAccepted)
    #expect(await offererRecord.messages.contains(message), "A states: \(offererStates)")
    #expect(await answererRecord.messages.contains(message), "B states: \(answererStates)")
    #expect(await offererRecord.messages.contains(control))
    #expect(await answererRecord.messages.contains(control))
    #expect(await offerer.configureIceServers([.init(urls: ["stun:localhost:3478"])]))
    await offerer.sendApplicationData(message, to: peer.id)
    let metrics = await offerer.networkStatistics(for: peer.id)
    #expect(metrics.bufferedBytes != nil)
    #expect(metrics.roundTripTime != nil)
    #expect(metrics.packetLoss == nil)
    await offerer.close(); await answerer.close()
    #expect(await offerer.networkStatistics(for: peer.id).bufferedBytes == nil)
    #expect(await offerer.sendApplicationData(message, to: peer.id) == false)
}

private func preparePair(
    offerer: WebRTCNativeEngine, answerer: WebRTCNativeEngine, peer: PeerDescriptor
) async {
    await offerer.createPeerConnection(for: peer)
    await answerer.createPeerConnection(for: peer)
    await offerer.configureDataChannels([
        .init(id: 2, isPublisher: true),
        .init(id: 4, peerID: .init(rawValue: "b")),
        .init(id: 6, isPublisher: true, delivery: .reliable),
        .init(id: 8, peerID: .init(rawValue: "b"), delivery: .reliable)
    ], for: peer.id)
    await answerer.configureDataChannels([
        .init(id: 4, isPublisher: true),
        .init(id: 2, peerID: .init(rawValue: "a")),
        .init(id: 8, isPublisher: true, delivery: .reliable),
        .init(id: 6, peerID: .init(rawValue: "a"), delivery: .reliable)
    ], for: peer.id)
}

@Test func internetMediaNeverFallsBackToTCPOrReliableTURN() async throws {
    let engine = WebRTCNativeEngine(iceServers: [])
    #expect(await !engine.configureIceServers([.init(urls: ["turn:relay:3478?transport=tcp", "turns:relay:5349"])]))
    #expect(await engine.configureIceServers([.init(urls: ["turn:relay:3478?transport=tcp", "stun:localhost:3478"])]))
    let peer = PeerDescriptor(id: .init(rawValue: "udp-only"), displayName: "UDP")
    await engine.createPeerConnection(for: peer)
    let offer = try #require(await engine.makeOffer(for: peer.id))
    let candidates = offer.sdp.components(separatedBy: "\n").filter { $0.hasPrefix("a=candidate:") }
    #expect(!candidates.isEmpty)
    #expect(candidates.allSatisfy { $0.lowercased().contains(" udp ") })
    await engine.close()
}

@Test func aReliableChannelCannotBeReusedAsAnAudioPublisher() async throws {
    let engine = WebRTCNativeEngine(iceServers: [])
    let peer = PeerDescriptor(id: .init(rawValue: "changed-allocation"), displayName: "Allocation")
    let recorder = PacketRecorder(), events = engine.events
    let task = Task { for await event in events { await recorder.record(event) } }
    defer { task.cancel() }
    await engine.createPeerConnection(for: peer)
    await engine.configureDataChannels([.init(id: 2, isPublisher: true, delivery: .reliable)], for: peer.id)
    await engine.configureDataChannels([.init(id: 2, isPublisher: true, delivery: .unreliable)], for: peer.id)
    for _ in 0..<20 where await !recorder.states.contains(.failed) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(
        await recorder.states.contains(.failed),
        "A changed delivery contract needs a fresh allocation; never send audio on the reliable channel"
    )
    await engine.close()
}
