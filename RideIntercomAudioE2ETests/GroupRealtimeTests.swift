import AVFAudio
import AudioCore
import Codec
import Foundation
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testEightPersonMixedRouteConversation() async throws {
        try await activateAudioSessionForTest()
        let probe = RenderedAudioProbe(), engine = AVAudioEngine()
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            probe.append(buffer, time: time)
        }
        let hardware = try output.startRendering(configuration: .intercomCall)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: (1..<8).map(String.init))
        defer { pipeline.stop(); engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
        let traffic = GroupAudioTraffic()
        try await traffic.start(pipeline: pipeline)
        defer { traffic.cancelObservation() }
        try await traffic.waitForMembership()
        probe.reset()
        let maximumSendIteration = try await traffic.sendConversation()
        try await Task.sleep(for: .milliseconds(300))
        await traffic.stop()
        let rendered = probe.snapshot()
        let waveform = ToneIntegrity.measure(
            samples: Array(rendered.samples.dropFirst(Int(rendered.rate * 2)).prefix(Int(rendered.rate * 1.8))),
            rate: rendered.rate, frequencies: Array(traffic.frequencies.dropFirst())
        )
        let delivery = traffic.observation.verifyOrderedDelivery(sent: traffic.sent)
        traffic.verifyDecodedConversation()
        XCTAssertTrue(
            traffic.sent.allSatisfy { $0 < 270 },
            "Quiet periods must remove over half of the 540 input packets per participant"
        )
        try attachGroupAudio(
            traffic: traffic, measurement: .init(waveform: waveform, delivery: delivery,
                                                  maximumSendIteration: maximumSendIteration),
            probe: probe, rendered: rendered
        )
        let errors = traffic.observation.errors
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertTrue(waveform.passed, String(describing: waveform.dictionary))
        XCTAssertLessThan(
            maximumSendIteration, 0.02, "Eight encode/send paths must finish inside their 20 ms input period"
        )
    }

    @MainActor
    private func attachGroupAudio(
        traffic: GroupAudioTraffic, measurement: GroupAudioMeasurement,
        probe: RenderedAudioProbe, rendered: RenderedAudioProbe.Recording
    ) throws {
        let waveform = measurement.waveform
        let delivery = measurement.delivery
        let errors = traffic.observation.errors
        let payload: [String: Any] = [
            "scenario": "eight-person-mixed", "role": "pipeline", "transport": "none",
            "participants": 8, "mixedRoutes": true, "sentPackets": traffic.sent, "lostPackets": delivery.losses,
            "duplicatePackets": delivery.duplicates,
            "maximumSendIterationSeconds": measurement.maximumSendIteration, "waveform": waveform.dictionary,
            "playoutChanges": traffic.observation.playoutChanges, "firstOutputHostTime": probe.firstOutputTime ?? 0,
            "processingFailures": errors, "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
            "continuityPassed": waveform.passed && delivery.losses == 0 && delivery.duplicates == 0 && errors.isEmpty
        ]
        try addAudioE2EJSONAttachment(payload, name: "eight-person-mixed-measurement", options: [.sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eight-person-mixed.wav")
        try probe.writeWAV(to: url, rendered: rendered)
        let audio = XCTAttachment(contentsOfFile: url)
        audio.name = "eight-person-mixed-audio"
        audio.lifetime = .keepAlways
        add(audio)
        try? FileManager.default.removeItem(at: url)
    }
}

private struct GroupPacketDelivery {
    let losses: Int
    let duplicates: Int
}

private struct GroupAudioMeasurement {
    let waveform: ToneIntegrity
    let delivery: GroupPacketDelivery
    let maximumSendIteration: Double
}

private struct GroupCodecSetting {
    let codec: CodecIdentifier
    let rate: Double
    let bitRate: Int
}

@MainActor
private final class GroupAudioTraffic {
    private let network = DelayedGroupNetwork()
    private let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer], [.multipeer, .webRTC], [.multipeer, .webRTC],
        [.webRTC], [.webRTC], [.multipeer, .webRTC], [.multipeer, .webRTC]]
    private let settings: [GroupCodecSetting] = [
        .init(codec: .pcm16, rate: 48000, bitRate: 32000),
        .init(codec: .opus, rate: 48000, bitRate: 48000),
        .init(codec: .opus, rate: 24000, bitRate: 64000),
        .init(codec: .opus, rate: 16000, bitRate: 128000),
        .init(codec: .mpeg4AACELD, rate: 48000, bitRate: 64000),
        .init(codec: .mpeg4AACELD, rate: 48000, bitRate: 32000),
        .init(codec: .mpeg4AACELD, rate: 24000, bitRate: 32000),
        .init(codec: .mpeg4AACELD, rate: 16000, bitRate: 24000)
    ]
    let frequencies = [230.0, 310, 430, 570, 710, 890, 1070, 1270]
    private var managers: [RouteManager] = []
    private var encoders: [StreamingCodecEncoder] = []
    private var listeners: [Task<Void, Never>] = []
    let observation = GroupAudioObservation()
    private(set) var sent = Array(repeating: UInt64(0), count: 8)

    func start(pipeline: AppAudioPipeline) async throws {
        for index in 0..<8 {
            let peer = PeerID(rawValue: String(index))
            let routes = kinds[index].map { DelayedGroupRoute(peer: peer, kind: $0, network: network) }
            let configuration = CallRouteConfiguration(
                enabledRoutes: kinds[index], preferredRoute: kinds[index].contains(.multipeer) ? .multipeer : .webRTC,
                fallbackDelay: 0
            )
            let manager = RouteManager(
                routes: routes, configuration: configuration,
                runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false)
            )
            let events = manager.events
            listeners.append(Task { @MainActor [observation] in
                for await event in events {
                    observation.observe(event, for: index, pipeline: pipeline)
                }
            })
            managers.append(manager)
            let setting = settings[index]
            encoders.append(try StreamingCodecEncoder(configuration: .init(
                codec: setting.codec, format: .init(sampleRate: setting.rate, channelCount: 1),
                aacELDv2Options: .init(bitRate: setting.bitRate), opusOptions: .init(bitRate: setting.bitRate)
            ), suppressesSilence: true))
            await manager.prepare(.init(
                sessionID: "eight-realtime", localPeer: .init(id: peer, displayName: String(index)),
                credential: .derived(groupID: "eight-realtime", secret: "fixture-only"), configuration: configuration,
                audioPolicy: .init(preferredCodecs: [.pcm16, .opus, .mpeg4AACELD])
            ))
            await manager.startConnection()
            await manager.startMedia()
        }
    }

    func cancelObservation() {
        listeners.forEach { $0.cancel() }
    }

    func waitForMembership() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while observation.records.contains(where: { $0.members != 7 }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(observation.records.allSatisfy { $0.members == 7 })
    }

    func sendConversation() async throws -> Double {
        let start = ContinuousClock.now
        var maximumSendIteration = 0.0
        for frameIndex in 0..<540 {
            try await Task.sleep(until: start + .milliseconds(frameIndex * 20), clock: .continuous)
            let began = ProcessInfo.processInfo.systemUptime
            for index in 0..<8 {
                let rate = settings[index].rate
                let count = Int(rate * 0.02)
                let samples = (0..<count).map { sample -> Float in
                    let time = Double(frameIndex * count + sample) / rate
                    return isSpeaking(at: time) ? Float(0.035 * sin(time * 2 * .pi * frequencies[index])) : 0
                }
                // Independent sender clocks, including negative epochs.
                let epoch = Double(index - 4) * 10000
                let frame = PCMFrame(
                    sequenceNumber: UInt64(frameIndex), format: .init(sampleRate: rate, channelCount: 1),
                    capturedAt: epoch + Double(frameIndex) * 0.02, samples: samples
                )
                guard let encoded = try encoders[index].encode(frame) else { continue }
                await managers[index].sendAudioPacket(.init(
                    sequenceNumber: sent[index], codec: .init(rawValue: encoded.codec.rawValue),
                    format: .init(sampleRate: rate, channelCount: 1), capturedAt: encoded.capturedAt,
                    sampleCount: encoded.sampleCount, bitRate: encoded.bitRate, payload: encoded.payload
                ))
                sent[index] += 1
            }
            maximumSendIteration = max(maximumSendIteration, ProcessInfo.processInfo.systemUptime - began)
        }
        return maximumSendIteration
    }

    func stop() async {
        for manager in managers { await manager.stopConnection() }
        await network.stop()
    }

    private func isSpeaking(at time: Double) -> Bool {
        time < 4 || (5..<5.1).contains(time) || (7.1..<7.2).contains(time) || (10.2..<10.3).contains(time)
    }

    func verifyDecodedConversation() {
        for index in 1..<8 {
            let frames = observation.decoded[String(index), default: []].filter { !$0.samples.isEmpty }
            let rate = settings[index].rate
            let epoch = Double(index - 4) * 10000
            let timeline = RenderedAudioProbe()
            for pair in zip(frames, frames.dropFirst()) {
                let end = pair.0.capturedAt + Double(pair.0.frameCount) / rate
                let gap = pair.1.capturedAt - end
                XCTAssertGreaterThan(gap, -1 / rate, "No overlapping sample at a codec boundary")
                if gap >= 1 / rate {
                    let gapStart = Int(((end - epoch) * rate).rounded())
                    let gapEnd = Int(((pair.1.capturedAt - epoch) * rate).rounded())
                    let missing = (gapStart..<gapEnd).filter { isSpeaking(at: Double($0) / rate) }
                    XCTAssertTrue(missing.isEmpty,
                        "Peer \(index) gap \(end - epoch)..<\(pair.1.capturedAt - epoch), "
                            + "voiced \(missing.count), first \(missing.first ?? -1): "
                            + "only silent source samples may be omitted")
                }
            }
            for frame in frames { timeline.append(frame, preservingTimeline: true) }
            let recorded = timeline.snapshot()
            XCTAssertEqual(recorded.invalid, 0)
            let samples = recorded.samples
            guard samples.count >= Int(rate * 10.35) else {
                XCTFail("Incomplete decoded conversation for peer \(index)")
                continue
            }
            for beginning in [5.0, 7.1, 10.2] {
                let window = samples[Int(beginning * rate)..<min(samples.count, Int((beginning + 0.15) * rate))]
                XCTAssertGreaterThan(
                    window.filter { abs($0) > 0.003 }.count, Int(rate * 0.07), "Short reply after silence must survive"
                )
            }
        }
    }
}

@MainActor
private final class GroupAudioObservation {
    let records = (0..<8).map { _ in GroupAudioRecord() }
    var errors: [String] = []
    var decoded: [String: [PCMFrame]] = [:]
    var playoutChanges: [[String: Any]] = []
    private var playoutCounts: [String: (Int, Int)] = [:]

    func observe(_ event: CallSessionEvent, for index: Int, pipeline: AppAudioPipeline) {
        switch event {
        case .membersChanged(let members):
            records[index].members = members.count
        case .receivedAudioPacket(let received):
            let peer = received.peerID.rawValue
            records[index].sequences[peer, default: []].append(received.packet.sequenceNumber)
            guard index == 0 else { return }
            do {
                decoded[peer, default: []].append(try pipeline.processReceivedAudioPacket(received))
                recordPlayoutChange(for: peer, capturedAt: received.packet.capturedAt, pipeline: pipeline)
            } catch {
                errors.append(String(describing: error))
            }
        default:
            break
        }
    }

    private func recordPlayoutChange(for peer: String, capturedAt: Double, pipeline: AppAudioPipeline) {
        if let state = pipeline.receivePlayoutDiagnostics(peerID: peer),
           playoutCounts[peer]?.0 != state.adjustments || playoutCounts[peer]?.1 != state.resets {
            playoutCounts[peer] = (state.adjustments, state.resets)
            playoutChanges.append([
                "peer": peer, "hostTime": ProcessInfo.processInfo.systemUptime,
                "capturedAt": capturedAt, "bufferedDuration": state.bufferedDuration,
                "adjustments": state.adjustments, "resets": state.resets
            ])
        }
    }

    func verifyOrderedDelivery(sent: [UInt64]) -> GroupPacketDelivery {
        var losses = 0
        var duplicates = 0
        for receiver in 0..<8 {
            for sender in 0..<8 where sender != receiver {
                let sequences = records[receiver].sequences[String(sender), default: []]
                duplicates += sequences.count - Set(sequences).count
                losses += Int(sent[sender]) - Set(sequences).count
                XCTAssertTrue(sequences == Array(0..<sent[sender]),
                    "sender \(sender) receiver \(receiver): \(sequences.count)/\(sent[sender]), "
                        + "first \(sequences.first.map(String.init) ?? "none"); require complete ordered delivery")
            }
        }
        return GroupPacketDelivery(losses: losses, duplicates: duplicates)
    }
}

@MainActor private final class GroupAudioRecord {
    var members = 0
    var sequences: [String: [UInt64]] = [:]
}

private actor DelayedGroupNetwork {
    var routes: [RouteKind: [PeerID: AsyncStream<RouteEvent>.Continuation]] = [:]
    var pending: [UUID: Task<Void, Never>] = [:]
    var counter = 0
    func join(_ peer: PeerID, kind: RouteKind, source: AsyncStream<RouteEvent>.Continuation) {
        routes[kind, default: [:]][peer] = source; publish(kind)
    }
    func leave(_ peer: PeerID, kind: RouteKind) { routes[kind]?[peer] = nil; publish(kind) }
    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        counter += 1
        let jitter = message.delivery == .unreliable ? counter % 5 : 0
        let delay = (kind == .multipeer ? 2 : 12) + (Int(peer.rawValue) ?? 0) * 3 + jitter
        let identity = UUID()
        pending[identity] = Task {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            deliver(peer, kind: kind, message: message)
            pending[identity] = nil
        }
    }
    func deliver(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        for (other, source) in routes[kind, default: [:]] where other != peer {
            source.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
        }
    }
    func publish(_ kind: RouteKind) {
        for (peer, source) in routes[kind, default: [:]] {
            let members = routes[kind, default: [:]].keys.filter { $0 != peer }.map {
                CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true)
            }
            source.yield(.membersChanged(kind, members))
            source.yield(.stateChanged(kind, kind == .webRTC ? .mediaReady : .authenticated))
        }
    }
    func stop() { pending.values.forEach { $0.cancel() }; pending.removeAll(); routes.removeAll() }
}
private actor DelayedGroupRoute: RTCCallRoute {
    let peer: PeerID
    let kind: RouteKind
    let network: DelayedGroupNetwork
    nonisolated let stream = AsyncStream<RouteEvent>.makeStream()
    nonisolated var events: AsyncStream<RouteEvent> { stream.stream }
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true,
        supportsReliableApplicationData: true, supportsUnreliableApplicationData: true, requiresSignaling: false,
        supportedAudioCodecs: [.pcm16, .opus, .mpeg4AACELD])
    init(peer: PeerID, kind: RouteKind, network: DelayedGroupNetwork) {
        self.peer = peer; self.kind = kind; self.network = network
    }
    func prepare(_ request: CallStartRequest) async {}
    func startConnection() async {await network.join(peer, kind: kind, source: stream.continuation)}
    func stopConnection() async {await network.leave(peer, kind: kind)}
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        await network.send(peer, kind: kind, message: message)
        guard kind == .multipeer else { return .init() }
        let recipients = Set(await network.routes[kind, default: [:]].keys).subtracting([peer])
        return .init(verifiedLocalRecipients: recipients)
    }
}
