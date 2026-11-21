#if DEBUG
import Foundation
import Network
import XCTest
@testable import RTC
@testable import RideIntercom

@MainActor
final class MixedRouteAudioE2E {
    private var localRoute: LocalCallRoute?

    func makeSession(routes: Set<RouteKind>, internet: CloudflareRealtimeConfiguration?) -> RTC.CallSession {
        let config = CallRouteConfiguration(enabledRoutes: routes, preferredRoute: .multipeer)
        let local = LocalCallRoute()
        localRoute = local
        var transports: [RTCCallRoute] = [local]
        if let internet {
            transports.append(WebRTCInternetRoute(cloudflareConfigurationProvider: { _ in internet },
                                                 engine: makeAudioE2EWebRTCEngine()))
        }
        return RouteManager(routes: transports, configuration: config)
    }

    func currentLocalMedia() async throws -> LocalDatagramTransport {
        try await Self.mediaTransport(XCTUnwrap(localRoute))
    }

    func verify(test: XCTestCase, pair: AudioE2EPair) async throws {
        let local = pair.endpoint.audio.input.samples
        let peer = PeerID(rawValue: pair.peerID)
        let barrier = pair.barrier
        let route = try XCTUnwrap(localRoute)
        let media = try await Self.mediaTransport(route)
        let localControl = LocalControlCounter(route: route, peer: peer)
        defer { localControl.stop() }
        try await waitForMixedRoute("Local media listener") { media.port != nil }
        let port = try XCTUnwrap(media.port)
        let localEndpoint = "\(port.rawValue):\(media.serviceNonce)"
        let endpoint = try await barrier.exchange("mixed-media-endpoint", value: localEndpoint)
        let components = endpoint.split(separator: ":", maxSplits: 1)
        let remotePortNumber = components.first.flatMap { UInt16($0) }
        let remotePort = try XCTUnwrap(remotePortNumber.flatMap { NWEndpoint.Port(rawValue: $0) })
        let remoteNonce = try XCTUnwrap(components.dropFirst().first.map(String.init))
        let proxy = try MediaBlackhole(target: remotePort)
        defer { proxy.stop() }
        print("Mixed Route E2E: Local listener exchange completed")
        let outboundBlockedAtStart = pair.endpoint.run.role == "a"
        proxy.setBlocked(outboundBlockedAtStart)
        media.connect(to: peer, nonce: remoteNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port))
        try await waitForMixedRoute("Local UDP path exists before application audio") { media.isReady(for: peer) }
        let observation = MixedRouteObservation(test: test, pair: pair, media: media, peer: peer, local: local)
        if pair.endpoint.run.startsBeforeInternet {
            try await observation.verifyLocalBeforeInternet(control: localControl)
        }
        try await observation.verifyInitialRoutes(control: localControl, proxy: proxy)
        try await observation.verifyLocalMediaLossAndRecovery(control: localControl, proxy: proxy)
        try await observation.verifyBlackoutAndEndCall(control: localControl, proxy: proxy)
    }

    // Inspect only the actor-owned references. Socket state has its own queue.
    private static func mediaTransport(_ route: isolated LocalCallRoute) throws -> LocalDatagramTransport {
        func storedValue(_ value: Any) -> Any? {
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .optional ? mirror.children.first?.value : value
        }
        let session = try XCTUnwrap(Mirror(reflecting: route).children.first { $0.label == "session" }
            .flatMap { storedValue($0.value) })
        let media = Mirror(reflecting: session).children.first { $0.label?.hasSuffix("datagrams") == true }
        return try XCTUnwrap(media.flatMap { storedValue($0.value) } as? LocalDatagramTransport)
    }
}

@MainActor
private struct MixedRouteObservation {
    let test: XCTestCase
    let pair: AudioE2EPair
    let media: LocalDatagramTransport
    let peer: PeerID
    let local: [Float]

    private var viewModel: IntercomViewModel { pair.endpoint.viewModel }
    private var input: SpeechFileInput { pair.endpoint.audio.input }
    private var probe: RenderedAudioProbe { pair.endpoint.audio.probe }
    private var directory: URL { pair.endpoint.directory }
    private var role: String { pair.endpoint.run.role }
    private var worker: AudioE2EWorker? { pair.endpoint.worker.fixture }
    private var barrier: AudioE2EBarrier { pair.barrier }
    private var seconds: Double { pair.endpoint.run.initial.seconds }
    private var outboundBlockedAtStart: Bool { role == "a" }
    private var startsBeforeInternet: Bool { pair.endpoint.run.startsBeforeInternet }

    func verifyLocalBeforeInternet(control localControl: LocalControlCounter) async throws {
        XCTAssertEqual(viewModel.availableCallRoutes, [.multipeer])
        XCTAssertEqual(viewModel.sentVoicePacketCount, 0)
        XCTAssertEqual(viewModel.receivedVoicePacketCount, 0)
        XCTAssertFalse(media.hasRecentMediaReceipt(for: peer))
        let controlBefore = localControl.receivedCount
        try await barrier.meet("mixed-first-speech-without-internet")
        try await measure("before-internet", blocked: !outboundBlockedAtStart, beginSpeech: true,
                          expectsRemoteSpeech: outboundBlockedAtStart)
        XCTAssertEqual(viewModel.availableCallRoutes, [.multipeer])
        XCTAssertGreaterThan(localControl.receivedCount, controlBefore)
        try await barrier.meet("mixed-internet-unavailable-observed")
        if role == "a" {
            let service = try XCTUnwrap(worker)
            await service.enableInternetSignaling()
        }
    }

    func verifyInitialRoutes(control localControl: LocalControlCounter, proxy: MediaBlackhole) async throws {
        let waitingForInternet = ContinuousClock.now
        try await waitForMixedRoute("Internet route becomes available", timeout: .seconds(30)) {
            viewModel.availableCallRoutes.contains(.webRTC)
        }
        print("Mixed Route E2E: Internet route available after \(waitingForInternet.duration(to: .now))")
        if !startsBeforeInternet {
            XCTAssertEqual(viewModel.sentVoicePacketCount, 0)
            XCTAssertEqual(viewModel.receivedVoicePacketCount, 0)
            XCTAssertFalse(media.hasRecentMediaReceipt(for: peer))
        }
        let initialControlCount = localControl.receivedCount
        try await barrier.meet("mixed-initial-one-way-blocked")
        try await measure("one-way-initial", blocked: !outboundBlockedAtStart, beginSpeech: !startsBeforeInternet)
        XCTAssertGreaterThan(localControl.receivedCount, initialControlCount, "QUIC control still reaches the peer")
        XCTAssertEqual(media.hasRecentMediaReceipt(for: peer), !outboundBlockedAtStart)
        if outboundBlockedAtStart { XCTAssertGreaterThan(proxy.droppedCount, 0) }
        try await barrier.meet("mixed-initial-one-way-observed")
        proxy.setBlocked(false)
        try await waitForMixedRoute("Authenticated Local audio through the proxy") {
            media.hasRecentMediaReceipt(for: peer)
        }
        try await barrier.meet("mixed-initial-local")
        try await measure("local-before", blocked: false)
    }

    func verifyLocalMediaLossAndRecovery(
        control localControl: LocalControlCounter, proxy: MediaBlackhole
    ) async throws {
        proxy.setBlocked(true)
        try await barrier.meet("mixed-media-blocked")
        // Let the old receipt expire and let any queued playback finish.
        try await Task.sleep(for: .seconds(LocalMediaReceiptWindow.lifetime + 0.3))
        XCTAssertFalse(media.hasRecentMediaReceipt(for: peer))
        XCTAssertTrue(media.isReady(for: peer))
        let controlBefore = localControl.receivedCount
        try await measure("internet-during", blocked: true)
        XCTAssertGreaterThan(
            localControl.receivedCount, controlBefore, "QUIC control must still reach the peer during UDP loss"
        )
        XCTAssertGreaterThan(proxy.droppedCount, 0)
        try await barrier.meet("mixed-about-to-restore")

        proxy.setBlocked(false)
        try await waitForMixedRoute("Local media receipt after restore") { media.hasRecentMediaReceipt(for: peer) }
        try await barrier.meet("mixed-local-restored")
        try await measure("local-after", blocked: false)
    }

    func verifyBlackoutAndEndCall(control localControl: LocalControlCounter, proxy: MediaBlackhole) async throws {
        let activeGroup = try XCTUnwrap(viewModel.activeGroupID)
        let dropsBefore = proxy.droppedCount
        let internetDropsBefore = await worker?.droppedMediaPackets ?? 0
        await worker?.setDropsMedia(true)
        proxy.setBlocked(true)
        try await barrier.meet("mixed-all-media-blocked")
        try await Task.sleep(for: .seconds(LocalMediaReceiptWindow.lifetime + 0.3))
        let receivedBefore = viewModel.receivedVoicePacketCount
        let sentBefore = viewModel.sentVoicePacketCount
        let controlBeforeEnd = localControl.receivedCount
        let localBeforeEnd = media.statistics.receivedMediaDatagrams ?? 0
        let pcmBefore = viewModel.audioPipeline.receiveDecodeCounts.pcmPackets
        let blackoutStartedAt = Date().timeIntervalSince1970
        probe.reset()
        // A complete publish interval is needed to observe a send decision made during the cut.
        try await Task.sleep(for: .seconds(seconds))
        let silence = probe.snapshot()
        let peak = silence.samples.reduce(Float(0)) { max($0, abs($1)) }
        XCTAssertEqual(silence.invalid, 0)
        XCTAssertGreaterThan(silence.samples.count, Int(silence.rate * seconds * 0.8))
        XCTAssertLessThan(peak, 0.001)
        XCTAssertEqual(viewModel.audioPipeline.receiveDecodeCounts.pcmPackets, pcmBefore)
        let blackout = try diagnostics(from: blackoutStartedAt, outgoing: .webRTC, expectsRemoteSpeech: false)
        try attachJSON(blackout.merging(["renderedSamples": silence.samples.count, "peak": peak]) { _, new in new },
                       name: "endpoint-\(role)-all-media-blocked-diagnostics")
        try await barrier.meet("mixed-ending-while-all-media-blocked")
        XCTAssertEqual(viewModel.receivedVoicePacketCount, receivedBefore)
        XCTAssertEqual(media.statistics.receivedMediaDatagrams ?? 0, localBeforeEnd)
        XCTAssertGreaterThan(viewModel.sentVoicePacketCount, sentBefore)
        XCTAssertGreaterThan(localControl.receivedCount, controlBeforeEnd)
        XCTAssertGreaterThan(proxy.droppedCount, dropsBefore)
        let internetDrops = await worker?.droppedMediaPackets ?? 0
        if worker != nil { XCTAssertGreaterThan(internetDrops, internetDropsBefore) }
        print(
            "Mixed Route E2E: All media blocked, received delta=0, Local drops=\(proxy.droppedCount - dropsBefore), "
                + "Internet drops=\(internetDrops - internetDropsBefore)"
        )
        try await verifyEndAfterBlackout(groupID: activeGroup, proxy: proxy)
    }

    private func verifyEndAfterBlackout(groupID: UUID, proxy: MediaBlackhole) async throws {
        if role == "a" {
            XCTAssertTrue(viewModel.endCall(viewModel.currentCallReference))
            try await waitForMixedRoute("The explicitly ended call releases its audio") { !viewModel.isAudioReady }
            await worker?.setDropsMedia(false)
        } else {
            try await waitForMixedRoute("The waiting peer observes the other endpoint leaving") {
                viewModel.authenticatedPeerIDs.isEmpty
            }
        }
        proxy.setBlocked(false)
        let verificationDeadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < verificationDeadline {
            XCTAssertTrue(viewModel.authenticatedPeerIDs.isEmpty)
            if role == "a" {
                XCTAssertNil(viewModel.activeGroupID, "Restoring routes must never revive the ended call")
                XCTAssertFalse(viewModel.hasAnyActiveGroupConnection)
                XCTAssertFalse(viewModel.isAudioReady)
            } else {
                XCTAssertEqual(viewModel.activeGroupID, groupID, "The peer keeps waiting in the original call")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Mixed Route E2E: Explicit end and peer wait verified after restoring media")
    }

    private func measure(
        _ phase: String, blocked: Bool, beginSpeech: Bool = false, expectsRemoteSpeech: Bool = true
    ) async throws {
        probe.reset()
        let firstReceived = viewModel.receivedVoicePacketCount
        let firstPCM = viewModel.audioPipeline.receiveDecodeCounts.pcmPackets
        let firstLocal = media.statistics.receivedMediaDatagrams ?? 0
        let observationStartedAt = Date().timeIntervalSince1970
        if beginSpeech { input.setFrameDeliveryEnabled(true) }
        let start = ContinuousClock.now
        repeat {
            XCTAssertTrue(viewModel.isAudioReady)
            XCTAssertEqual(viewModel.authenticatedPeerIDs, [peer.rawValue])
            XCTAssertNil(viewModel.audioErrorMessage)
            try await Task.sleep(for: .milliseconds(100))
        } while start.duration(to: .now) < .seconds(seconds)
        let render = probe.snapshot()
        let received = viewModel.receivedVoicePacketCount - firstReceived
        let decoded = viewModel.audioPipeline.receiveDecodeCounts.pcmPackets - firstPCM
        let localDatagrams = (media.statistics.receivedMediaDatagrams ?? 0) - firstLocal
        print("Mixed Route E2E: Render sampled during \(phase), received=\(received), Local=\(localDatagrams)")
        let internetFallback = phase == "internet-during" || (phase == "one-way-initial" && outboundBlockedAtStart)
        let observation = try diagnostics(
            from: observationStartedAt, outgoing: internetFallback ? .webRTC : .multipeer,
            expectsRemoteSpeech: expectsRemoteSpeech
        )
        try await barrier.meet("mixed-measured-" + phase)
        let remote = pair.endpoint.audio.remote.samples
        let local = self.local
        let (remoteMatch, localMatch) = await Task.detached {
            (RenderedAudioProbe.speechMatch(reference: remote, referenceRate: 48000,
                output: render.samples, outputRate: render.rate),
             RenderedAudioProbe.speechMatch(reference: local, referenceRate: 48000,
                output: render.samples, outputRate: render.rate))
        }.value
        verifyRender(render, phase: phase, counts: .init(received: received, decoded: decoded, local: localDatagrams),
                     matching: .init(remote: remoteMatch, local: localMatch),
                     expectation: .init(expectsRemoteSpeech: expectsRemoteSpeech, blocked: blocked))
        let evidence: [String: Any] = ["scenario": phase, "role": role, "transport": "mixed",
            "received": received, "decoded": decoded, "receivedLocalDatagrams": localDatagrams,
            "remoteMatch": remoteMatch, "localMatch": localMatch, "renderedSamples": render.samples.count,
            "renderedRate": render.rate, "diagnostics": observation]
        try attachJSON(evidence, name: "endpoint-\(role)-\(phase)-measurement")
        try await attachSpeech(render, phase: phase)
    }

}

private extension MixedRouteObservation {
    func verifyRender(
        _ render: RenderedAudioProbe.Recording, phase: String, counts: MixedRouteCounts,
        matching: MixedRouteSpeechMatch, expectation: MixedRouteExpectation
    ) {
        XCTAssertEqual(render.invalid, 0)
        XCTAssertGreaterThan(render.samples.count, Int(render.rate * seconds * 0.8))
        if expectation.expectsRemoteSpeech {
            XCTAssertGreaterThan(counts.received, 20)
            XCTAssertGreaterThan(counts.decoded, 20)
            XCTAssertGreaterThan(matching.remote, 0.45, "Missing the remote voice during " + phase)
            XCTAssertGreaterThan(
                matching.remote, matching.local + 0.10, "Local audio cannot satisfy the remote voice oracle"
            )
        } else {
            XCTAssertEqual(counts.received, 0)
            XCTAssertEqual(counts.decoded, 0)
            XCTAssertLessThan(render.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.001)
        }
        if expectation.blocked {
            XCTAssertEqual(counts.local, 0, "The receiver must not get Local audio during the cut")
        } else {
            XCTAssertGreaterThan(counts.local, 20, "The Local route must carry current media")
        }
    }

    private func attachSpeech(_ render: RenderedAudioProbe.Recording, phase: String) async throws {
        let probe = self.probe
        let wav = directory.appendingPathComponent("mixed-\(role)-\(phase).wav")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.detached { try probe.writeWAV(to: wav, rendered: render) }.value
        let recording = XCTAttachment(contentsOfFile: wav)
        recording.name = "endpoint-\(role)-\(phase)-speech"
        recording.lifetime = .keepAlways
        test.add(recording)
    }

    func diagnostics(from startedAt: TimeInterval, outgoing: RouteKind,
                     expectsRemoteSpeech: Bool) throws -> [String: Any] {
        let input = DiagnosticsInput(viewModel)
        let receivePipeline = ReceivePipelinePresentation(input: input)
        let transmitRoutes = TransmitPipelinePresentation(input: input).outboundRoutes(now: input.capturedAt)
        let dispatch = try XCTUnwrap(input.networkDiagnostics?.outboundAudioDispatch)
        XCTAssertGreaterThanOrEqual(dispatch.observedAt, startedAt, "Use a dispatch observed in this interval")
        let send = try XCTUnwrap(transmitRoutes.branches.first { $0.id == outgoing.rawValue })
        XCTAssertEqual(dispatch.transportAcceptance?[outgoing], true, "\(send.title): \(send.detail)")
        XCTAssertEqual(send.state, .passing, "\(send.title): \(send.detail)")

        let expectedState: PipelineStepState = expectsRemoteSpeech ? .passing : .waiting
        let receive = [receivePipeline.rtcReceiveStep, receivePipeline.codecDecodeStep, receivePipeline.outputStep]
        for stage in receive {
            XCTAssertEqual(stage.state, expectedState, "\(stage.title): \(stage.detail)")
        }
        return [
            "intervalStartedAt": startedAt, "capturedAt": input.capturedAt,
            "dispatchAt": dispatch.observedAt, "outgoingRoute": outgoing.rawValue,
            "transmit": transmitRoutes.branches.map {
                ["stage": $0.title, "state": $0.state.statusText, "detail": $0.detail]
            },
            "receive": receive.map { ["stage": $0.title, "state": $0.state.statusText, "detail": $0.detail] },
            "lastReceiptAt": input.lastReceivedAudioAt as Any? ?? NSNull(),
            "lastPCMAt": input.receiveDecodeCounts.lastPCMAt as Any? ?? NSNull(),
            "lastAudibleAt": input.lastNativeAudibleOutputAt as Any? ?? NSNull()
        ]
    }

    func attachJSON(_ evidence: [String: Any], name: String) throws {
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

private struct MixedRouteCounts {
    let received: Int
    let decoded: Int
    let local: UInt64
}

private struct MixedRouteSpeechMatch {
    let remote: Float
    let local: Float
}

private struct MixedRouteExpectation {
    let expectsRemoteSpeech: Bool
    let blocked: Bool
}

@MainActor
private func waitForMixedRoute(
    _ description: String, timeout: Duration = .seconds(12), condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    _ = try XCTUnwrap(condition() ? true : nil, description)
}

/// Count control from the actual QUIC route independently of the rendezvous.
@MainActor
private final class LocalControlCounter {
    private(set) var receivedCount = 0
    private var task: Task<Void, Never>?

    init(route: LocalCallRoute, peer: PeerID) {
        let events = route.events
        task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .receivedApplicationData(.multipeer, let data) = event,
                   data.peerID == peer, data.message.delivery == .reliable {
                    receivedCount += 1
                }
            }
        }
    }

    func stop() { task?.cancel() }
}
#endif
