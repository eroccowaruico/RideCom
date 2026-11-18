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

    func verify(test: XCTestCase, viewModel: IntercomViewModel, peer: PeerID, role: String, worker: AudioE2EWorker?,
                barrier: AudioE2EBarrier, probe: RenderedAudioProbe, input: SpeechFileInput, remote: [Float],
                directory: URL, seconds: Double, startsBeforeInternet: Bool) async throws {
        let local = input.samples
        let route = try XCTUnwrap(localRoute)
        let media = try await Self.mediaTransport(route)
        let localControl = LocalControlCounter(route: route, peer: peer)
        defer { localControl.stop() }
        try await waitFor("Local media listener") { media.port != nil }
        let port = try XCTUnwrap(media.port)
        let endpoint = try await barrier.exchange("mixed-media-endpoint", value: "\(port.rawValue):\(media.serviceNonce)")
        let components = endpoint.split(separator: ":", maxSplits: 1)
        let remotePort = try XCTUnwrap(components.first.flatMap { UInt16($0) }.flatMap { NWEndpoint.Port(rawValue: $0) })
        let remoteNonce = try XCTUnwrap(components.dropFirst().first.map(String.init))
        let proxy = try MediaBlackhole(target: remotePort)
        defer { proxy.stop() }
        print("Mixed Route E2E: Local listener exchange completed")
        let outboundBlockedAtStart = role == "a"
        proxy.setBlocked(outboundBlockedAtStart)
        media.connect(to: peer, nonce: remoteNonce, endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port))
        try await waitFor("Local UDP path exists before application audio") { media.isReady(for: peer) }
        if startsBeforeInternet {
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
        let waitingForInternet = ContinuousClock.now
        try await waitFor("Internet route becomes available", timeout: .seconds(30)) {
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
        try await waitFor("Authenticated Local audio through the proxy") { media.hasRecentMediaReceipt(for: peer) }
        try await barrier.meet("mixed-initial-local")
        try await measure("local-before", blocked: false)

        proxy.setBlocked(true)
        try await barrier.meet("mixed-media-blocked")
        // Let the old receipt expire and let any queued playback finish.
        try await Task.sleep(for: .seconds(LocalMediaReceiptWindow.lifetime + 0.3))
        XCTAssertFalse(media.hasRecentMediaReceipt(for: peer))
        XCTAssertTrue(media.isReady(for: peer))
        let controlBefore = localControl.receivedCount
        try await measure("internet-during", blocked: true)
        XCTAssertGreaterThan(localControl.receivedCount, controlBefore, "QUIC control must still reach the peer during UDP loss")
        XCTAssertGreaterThan(proxy.droppedCount, 0)
        try await barrier.meet("mixed-about-to-restore")

        proxy.setBlocked(false)
        try await waitFor("Local media receipt after restore") { media.hasRecentMediaReceipt(for: peer) }
        try await barrier.meet("mixed-local-restored")
        try await measure("local-after", blocked: false)

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
        try await Task.sleep(for: .seconds(2))
        try await barrier.meet("mixed-ending-while-all-media-blocked")
        XCTAssertEqual(viewModel.receivedVoicePacketCount, receivedBefore)
        XCTAssertEqual(media.statistics.receivedMediaDatagrams ?? 0, localBeforeEnd)
        XCTAssertGreaterThan(viewModel.sentVoicePacketCount, sentBefore)
        XCTAssertGreaterThan(localControl.receivedCount, controlBeforeEnd)
        XCTAssertGreaterThan(proxy.droppedCount, dropsBefore)
        let internetDrops = await worker?.droppedMediaPackets ?? 0
        if worker != nil { XCTAssertGreaterThan(internetDrops, internetDropsBefore) }
        print("Mixed Route E2E: All media blocked, received delta=0, Local drops=\(proxy.droppedCount - dropsBefore), Internet drops=\(internetDrops - internetDropsBefore)")
        if role == "a" {
            XCTAssertTrue(viewModel.endCall(viewModel.currentCallReference))
            try await waitFor("The explicitly ended call releases its audio") { !viewModel.isAudioReady }
            await worker?.setDropsMedia(false)
        } else {
            try await waitFor("The waiting peer observes the other endpoint leaving") { viewModel.authenticatedPeerIDs.isEmpty }
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
                XCTAssertEqual(viewModel.activeGroupID, activeGroup, "The peer keeps waiting in the original call")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("Mixed Route E2E: Explicit end and peer wait verified after restoring media")

        func measure(_ phase: String, blocked: Bool, beginSpeech: Bool = false, expectsRemoteSpeech: Bool = true) async throws {
            probe.reset()
            let firstReceived = viewModel.receivedVoicePacketCount
            let firstLocal = media.statistics.receivedMediaDatagrams ?? 0
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
            let localDatagrams = (media.statistics.receivedMediaDatagrams ?? 0) - firstLocal
            print("Mixed Route E2E: Render sampled during \(phase), received=\(received), Local=\(localDatagrams)")
            try await barrier.meet("mixed-measured-" + phase)
            let (remoteMatch, localMatch) = await Task.detached {
                (RenderedAudioProbe.speechMatch(reference: remote, referenceRate: 48000, output: render.samples, outputRate: render.rate),
                 RenderedAudioProbe.speechMatch(reference: local, referenceRate: 48000, output: render.samples, outputRate: render.rate))
            }.value
            XCTAssertEqual(render.invalid, 0)
            XCTAssertGreaterThan(render.samples.count, Int(render.rate * seconds * 0.8))
            if expectsRemoteSpeech {
                XCTAssertGreaterThan(received, 20)
                XCTAssertGreaterThan(remoteMatch, 0.45, "Missing the remote voice during " + phase)
                XCTAssertGreaterThan(remoteMatch, localMatch + 0.10, "Local audio cannot satisfy the remote voice oracle")
            } else {
                XCTAssertEqual(received, 0)
                XCTAssertLessThan(render.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.001)
            }
            if blocked { XCTAssertEqual(localDatagrams, 0, "The receiver must not get Local audio during the cut") }
            else { XCTAssertGreaterThan(localDatagrams, 20, "The Local route must carry current media") }
            let evidence: [String: Any] = ["scenario": phase, "role": role, "transport": "mixed",
                "received": received, "receivedLocalDatagrams": localDatagrams, "remoteMatch": remoteMatch,
                "localMatch": localMatch, "renderedSamples": render.samples.count, "renderedRate": render.rate]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence),
                                           uniformTypeIdentifier: "public.json")
            attachment.name = "endpoint-\(role)-\(phase)-measurement"
            attachment.lifetime = .keepAlways
            test.add(attachment)
            let wav = directory.appendingPathComponent("mixed-\(role)-\(phase).wav")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await Task.detached { try probe.writeWAV(to: wav, rendered: render) }.value
            let recording = XCTAttachment(contentsOfFile: wav)
            recording.name = "endpoint-\(role)-\(phase)-speech"
            recording.lifetime = .keepAlways
            test.add(recording)
        }
    }

    private func waitFor(_ description: String, timeout: Duration = .seconds(12), condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        _ = try XCTUnwrap(condition() ? true : nil, description)
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
