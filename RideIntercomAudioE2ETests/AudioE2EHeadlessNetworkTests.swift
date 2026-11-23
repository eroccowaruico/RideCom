import AVFAudio
import Foundation
import RTC
import XCTest

private actor HeadlessSpeechReceiver {
    private(set) var isReady = false
    private var payloads: [UInt64: Data] = [:]

    func record(_ event: CallSessionEvent) {
        switch event {
        case .membersChanged(let members):
            isReady = members.contains { $0.isConnected && $0.route == .webRTC }
        case .receivedAudioPacket(let received):
            payloads[received.packet.sequenceNumber] = received.packet.payload
        default:
            break
        }
    }

    func matchingFrames(_ sent: [RTCAudioPacket]) -> Int {
        sent.count { payloads[$0.sequenceNumber] == $0.payload }
    }
}

extension AudioE2ETests {
    @MainActor
    func testWebRTCDuplexSpeechWithoutAudioHardware() async throws {
        let room = UUID().uuidString
        let credential = RTCCredential.derived(groupID: room, secret: room)
        let sentA = try speechPackets(named: "speech")
        let sentB = try speechPackets(named: "reply")
        let frameCount = min(sentA.count, sentB.count)
        let server = try AudioE2EWorker(port: 0, run: room, room: credential.groupHash)
        try await server.start()
        do {
            let listeningPort = await server.listeningPort
            let port = try XCTUnwrap(listeningPort)
            let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
            await exchangeSpeech(sentA: Array(sentA.prefix(frameCount)), sentB: Array(sentB.prefix(frameCount)),
                                     room: room, credential: credential, origin: origin)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
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
        sentA: [RTCAudioPacket], sentB: [RTCAudioPacket], room: String, credential: RTCCredential, origin: URL
    ) async {
        let left = await speechSession(role: "a", room: room, credential: credential, origin: origin)
        let right = await speechSession(role: "b", room: room, credential: credential, origin: origin)
        let heardLeft = HeadlessSpeechReceiver(), heardRight = HeadlessSpeechReceiver()
        let receiveLeft = Task { for await event in left.events { await heardLeft.record(event) } }
        let receiveRight = Task { for await event in right.events { await heardRight.record(event) } }
        defer { receiveLeft.cancel(); receiveRight.cancel() }
        await left.startConnection()
        await right.startConnection()
        await left.startMedia()
        await right.startMedia()
        var bothReady = false
        for _ in 0..<150 where !bothReady {
            let ready = await (heardLeft.isReady, heardRight.isReady)
            bothReady = ready.0 && ready.1
            if !bothReady { try? await Task.sleep(for: .milliseconds(100)) }
        }
        if bothReady {
            for (packetA, packetB) in zip(sentA, sentB) {
                await left.sendAudioPacket(packetA)
                await right.sendAudioPacket(packetB)
                try? await Task.sleep(for: .milliseconds(20))
            }
            try? await Task.sleep(for: .seconds(2))
        }
        await left.stopMedia()
        await right.stopMedia()
        await left.stopConnection()
        await right.stopConnection()
        XCTAssertTrue(bothReady, "Both peers must authenticate over WebRTC")
        let leftFrames = await heardLeft.matchingFrames(sentB), rightFrames = await heardRight.matchingFrames(sentA)
        XCTAssertGreaterThanOrEqual(leftFrames, sentB.count * 9 / 10)
        XCTAssertGreaterThanOrEqual(rightFrames, sentA.count * 9 / 10)
        print("WebRTC speech frames: left \(leftFrames)/\(sentB.count), right \(rightFrames)/\(sentA.count)")
    }

    private func speechSession(
        role: String, room: String, credential: RTCCredential, origin: URL
    ) async -> RouteManager {
        let configuration = CallRouteConfiguration(enabledRoutes: [.webRTC], preferredRoute: .webRTC)
        let internet = CloudflareRealtimeConfiguration(workerURL: origin, accessToken: room)
        let routes = CallSessionFactory.makeRoutes(.init(routeConfiguration: configuration, webRTC: .init(
            cloudflareConfigurationProvider: { _ in internet }, engineFactory: { makeAudioE2EWebRTCEngine() })))
        let session = RouteManager(routes: routes, configuration: configuration)
        let peer = PeerDescriptor(id: .init(rawValue: "e2e-\(role)-\(room.prefix(8))"), displayName: role)
        await session.prepare(
            .init(sessionID: room, localPeer: peer, credential: credential, configuration: configuration))
        return session
    }
}
