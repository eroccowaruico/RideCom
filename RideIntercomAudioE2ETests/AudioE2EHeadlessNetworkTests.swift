import AVFAudio
import Foundation
import RTC
@preconcurrency import WebRTC
import XCTest

private actor HeadlessSpeechReceiver {
    private(set) var isReady = false
    private var payloads: [UInt64: Data] = [:]
    private var callState: CallConnectionState = .idle
    private var hasInternetRoute = false
    private var observingWait = false
    private var interruptedWait = false

    var receivedAudio: Bool { !payloads.isEmpty }

    private var isWaitingAlone: Bool {
        callState == .connecting && hasInternetRoute && !isReady && payloads.isEmpty
    }

    func record(_ event: CallSessionEvent) {
        switch event {
        case .membersChanged(let members):
            isReady = members.contains { $0.isConnected && $0.route == .webRTC }
        case .stateChanged(let state):
            callState = state
        case .routeChanged(let snapshot):
            hasInternetRoute = snapshot.availableRoutes.contains(.webRTC)
        case .receivedAudioPacket(let received):
            payloads[received.packet.sequenceNumber] = received.packet.payload
        default:
            break
        }
        if observingWait && !isWaitingAlone { interruptedWait = true }
    }

    func beginObservingAlone() -> Bool {
        guard isWaitingAlone else { return false }
        observingWait = true
        return true
    }

    func finishObservingAlone() -> Bool {
        defer { observingWait = false }
        return observingWait && !interruptedWait && isWaitingAlone
    }

    func matchingFrames(_ sent: ArraySlice<RTCAudioPacket>, startingAt firstSequence: UInt64) -> Int {
        sent.enumerated().count { index, packet in
            payloads[firstSequence + UInt64(index)] == packet.payload
        }
    }
}

private struct HeadlessSpeechTrial: Decodable {
    let room: String
    let groupSecret: String
    let leftToken: String
    let rightToken: String
}

private struct HeadlessSpeechOptions {
    let requiresRelay: Bool
    let waitsForPeer: Bool
}

private final class RelayOnlyPeerConnectionFactory: RTCPeerConnectionFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: RTCPeerConnection?

    override func peerConnection(with configuration: RTCConfiguration, constraints: RTCMediaConstraints,
                                 delegate: RTCPeerConnectionDelegate?) -> RTCPeerConnection? {
        configuration.iceTransportPolicy = .relay
        let created = super.peerConnection(with: configuration, constraints: constraints, delegate: delegate)
        lock.withLock { connection = created }
        return created
    }

    func usesUDPRelay() async -> Bool {
        guard let connection = lock.withLock({ self.connection }) else { return false }
        return await withCheckedContinuation { continuation in
            connection.statistics { report in
                // The selected local candidate proves relay use even when the remote SFU
                // advertises direct candidates. relayProtocol is the client-to-TURN transport.
                let usesUDPRelay = report.statistics.values.contains { transport in
                    guard transport.type == "transport",
                          let pairID = transport.values["selectedCandidatePairId"] as? String,
                          let pair = report.statistics[pairID],
                          let candidateID = pair.values["localCandidateId"] as? String,
                          let candidate = report.statistics[candidateID] else { return false }
                    return candidate.values["candidateType"] as? String == "relay"
                        && candidate.values["relayProtocol"] as? String == "udp"
                }
                continuation.resume(returning: usesUDPRelay)
            }
        }
    }
}

extension AudioE2ETests {
    @MainActor
    func testWebRTCDuplexSpeechWithoutAudioHardware() async throws {
        let sentA = try speechPackets(named: "speech")
        let sentB = try speechPackets(named: "reply")
        let frameCount = min(sentA.count, sentB.count)
        let framesA = Array(sentA.prefix(frameCount)), framesB = Array(sentB.prefix(frameCount))
        let environment = ProcessInfo.processInfo.environment
        let options = HeadlessSpeechOptions(
            requiresRelay: environment["RIDEINTERCOM_TEST_TURN_RELAY"] == "1",
            waitsForPeer: environment["RIDEINTERCOM_TEST_WAIT_FOR_PEER"] == "1"
        )
        if let bootstrap = environment["RIDEINTERCOM_PREVIEW_MEDIA_BOOTSTRAP"] {
            let trial = try await loadPreviewMediaTrial(bootstrap)
            let origin = try XCTUnwrap(URL(string: "https://preview-rideintercom.analog.workers.dev"))
            await exchangeSpeech(sentA: framesA, sentB: framesB, trial: trial, origin: origin, options: options)
            return
        }
        let room = UUID().uuidString
        let trial = HeadlessSpeechTrial(room: room, groupSecret: room, leftToken: room, rightToken: room)
        let credential = RTCCredential.derived(groupID: room, secret: room)
        var serverICE = WebRTCIceServer(urls: ["stun:127.0.0.1:9"])
        if options.requiresRelay {
            let port = try XCTUnwrap(environment["RIDEINTERCOM_TEST_LOCAL_TURN_PORT"].flatMap(UInt16.init))
            serverICE = .init(urls: ["turn:127.0.0.1:\(port)?transport=udp"],
                              username: "relay-fixture", credential: "loopback-fixture")
        }
        let server = try AudioE2EWorker(port: 0, run: room, room: credential.groupHash, iceServer: serverICE)
        try await server.start()
        do {
            let listeningPort = await server.listeningPort
            let port = try XCTUnwrap(listeningPort)
            let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
            await exchangeSpeech(sentA: framesA, sentB: framesB, trial: trial, origin: origin, options: options)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    private func loadPreviewMediaTrial(_ bootstrap: String) async throws -> HeadlessSpeechTrial {
        guard let url = URL(string: bootstrap), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.user == nil, url.password == nil else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 5))
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url == url, data.count <= 1024 else {
            throw URLError(.userAuthenticationRequired)
        }
        return try JSONDecoder().decode(HeadlessSpeechTrial.self, from: data)
    }

    private func speechPackets(named name: String) throws -> [RTCAudioPacket] {
        let url = try XCTUnwrap(Bundle(for: AudioE2ETests.self).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = file.processingFormat
        XCTAssertEqual(format.channelCount, 1)
        let framesPerPacket = Int(format.sampleRate / 50)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(100 * framesPerPacket)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.int16ChannelData)[0]
        let count = Int(buffer.frameLength) / framesPerPacket
        XCTAssertGreaterThanOrEqual(count, 50)
        return (0..<count).map { index in
            let bytes = Data(bytes: channel + (index * framesPerPacket), count: framesPerPacket * 2)
            return .init(sequenceNumber: UInt64(index), codec: .pcm16,
                         format: .init(sampleRate: format.sampleRate, channelCount: 1), payload: bytes)
        }
    }

    private func exchangeSpeech(
        sentA: [RTCAudioPacket], sentB: [RTCAudioPacket], trial: HeadlessSpeechTrial, origin: URL,
        options: HeadlessSpeechOptions
    ) async {
        let leftFactory = options.requiresRelay ? RelayOnlyPeerConnectionFactory() : nil
        let rightFactory = options.requiresRelay ? RelayOnlyPeerConnectionFactory() : nil
        let left = await speechSession(role: "a", token: trial.leftToken, trial: trial, origin: origin,
                                       relayFactory: leftFactory)
        let right = await speechSession(role: "b", token: trial.rightToken, trial: trial, origin: origin,
                                        relayFactory: rightFactory)
        let heardLeft = HeadlessSpeechReceiver(), heardRight = HeadlessSpeechReceiver()
        let receiveLeft = Task { for await event in left.events { await heardLeft.record(event) } }
        let receiveRight = Task { for await event in right.events { await heardRight.record(event) } }
        defer { receiveLeft.cancel(); receiveRight.cancel() }
        let firstDuplexFrame = options.waitsForPeer ? 25 : 0
        let duplexA = sentA.dropFirst(firstDuplexFrame), duplexB = sentB.dropFirst(firstDuplexFrame)
        var bothReady = await startSpeechSessions(left, right, heardLeft: heardLeft, heardRight: heardRight,
                                                  waitsForPeer: options.waitsForPeer)
        if bothReady, let leftFactory, let rightFactory {
            bothReady = await checkUDPRelay(leftFactory, rightFactory)
        }
        if bothReady {
            if options.waitsForPeer {
                let intro = (left: sentA.prefix(firstDuplexFrame), right: sentB.prefix(firstDuplexFrame))
                await checkMutedReception(left, right, heardLeft: heardLeft, heardRight: heardRight, frames: intro)
                await left.setLocalMute(false)
            }
            await sendSpeech(left, right, framesA: duplexA, framesB: duplexB)
            try? await Task.sleep(for: .seconds(2))
            if let leftFactory, let rightFactory {
                bothReady = await checkUDPRelay(leftFactory, rightFactory)
            }
        }
        await left.stopMedia()
        await right.stopMedia()
        await left.stopConnection()
        await right.stopConnection()
        XCTAssertTrue(bothReady, "Both peers must authenticate over WebRTC")
        // The relay numbers transmitted frames. The muted side starts at zero after unmuting.
        let leftFrames = await heardLeft.matchingFrames(duplexB, startingAt: UInt64(firstDuplexFrame))
        let rightFrames = await heardRight.matchingFrames(duplexA, startingAt: 0)
        XCTAssertGreaterThanOrEqual(leftFrames * 10, duplexB.count * 9)
        XCTAssertGreaterThanOrEqual(rightFrames * 10, duplexA.count * 9)
        print("WebRTC speech frames: left \(leftFrames)/\(duplexB.count), right \(rightFrames)/\(duplexA.count)")
    }

    private func startSpeechSessions(
        _ left: RouteManager, _ right: RouteManager, heardLeft: HeadlessSpeechReceiver,
        heardRight: HeadlessSpeechReceiver, waitsForPeer: Bool
    ) async -> Bool {
        if waitsForPeer { await left.setLocalMute(true) }
        await left.startConnection()
        if waitsForPeer {
            await left.startMedia()
            let waited = await observeWaitingPeer(heardLeft)
            XCTAssertTrue(waited, "The first peer must remain alone on the Internet route")
            guard waited else { return false }
        }
        await right.startConnection()
        if !waitsForPeer { await left.startMedia() }
        await right.startMedia()
        return await waitForSpeechCondition {
            let ready = await (heardLeft.isReady, heardRight.isReady)
            return ready.0 && ready.1
        }
    }

    private func checkMutedReception(
        _ left: RouteManager, _ right: RouteManager, heardLeft: HeadlessSpeechReceiver,
        heardRight: HeadlessSpeechReceiver,
        frames: (left: ArraySlice<RTCAudioPacket>, right: ArraySlice<RTCAudioPacket>)
    ) async {
        await sendSpeech(left, right, framesA: frames.left, framesB: frames.right)
        let receivedWhileMuted = await waitForSpeechCondition {
            await heardLeft.matchingFrames(frames.right, startingAt: 0) * 10 >= frames.right.count * 9
        }
        let mutedPeerSentAudio = await heardRight.receivedAudio
        XCTAssertTrue(receivedWhileMuted, "The waiting peer must receive speech while muted")
        XCTAssertFalse(mutedPeerSentAudio, "The muted peer must not send speech")
        if receivedWhileMuted && !mutedPeerSentAudio {
            let mutedFrames = await heardLeft.matchingFrames(frames.right, startingAt: 0)
            print("WebRTC late join: 20 seconds waiting, listen-only \(mutedFrames)/\(frames.right.count)")
        }
    }

    private func observeWaitingPeer(_ receiver: HeadlessSpeechReceiver) async -> Bool {
        guard await waitForSpeechCondition({ await receiver.beginObservingAlone() }) else { return false }
        do { try await Task.sleep(for: .seconds(20)) } catch { return false }
        return await receiver.finishObservingAlone()
    }

    private func waitForSpeechCondition(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<150 {
            if await condition() { return true }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    private func sendSpeech(_ left: RouteManager, _ right: RouteManager,
                            framesA: ArraySlice<RTCAudioPacket>, framesB: ArraySlice<RTCAudioPacket>) async {
        for (packetA, packetB) in zip(framesA, framesB) {
            await left.sendAudioPacket(packetA)
            await right.sendAudioPacket(packetB)
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        }
    }

    private func speechSession(
        role: String, token: String, trial: HeadlessSpeechTrial, origin: URL,
        relayFactory: RelayOnlyPeerConnectionFactory?
    ) async -> RouteManager {
        let configuration = CallRouteConfiguration(enabledRoutes: [.webRTC], preferredRoute: .webRTC)
        let internet = CloudflareRealtimeConfiguration(workerURL: origin, accessToken: token)
        let routes = CallSessionFactory.makeRoutes(.init(routeConfiguration: configuration, webRTC: .init(
            cloudflareConfigurationProvider: { _ in internet },
            engineFactory: { makeAudioE2EWebRTCEngine(factory: relayFactory ?? RTCPeerConnectionFactory()) })))
        let session = RouteManager(routes: routes, configuration: configuration)
        let peer = PeerDescriptor(id: .init(rawValue: "e2e-\(role)-\(trial.room.prefix(8))"), displayName: role)
        let credential = RTCCredential.derived(groupID: trial.room, secret: trial.groupSecret)
        await session.prepare(
            .init(sessionID: trial.room, localPeer: peer, credential: credential, configuration: configuration))
        return session
    }

    private func checkUDPRelay(
        _ left: RelayOnlyPeerConnectionFactory, _ right: RelayOnlyPeerConnectionFactory
    ) async -> Bool {
        let leftRelays = await left.usesUDPRelay()
        let rightRelays = await right.usesUDPRelay()
        print("WebRTC UDP TURN selected: left \(leftRelays), right \(rightRelays)")
        XCTAssertTrue(leftRelays && rightRelays, "Both selected ICE paths must use UDP TURN")
        return leftRelays && rightRelays
    }
}
