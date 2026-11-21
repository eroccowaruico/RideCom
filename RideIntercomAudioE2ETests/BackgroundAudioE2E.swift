import CallControl
import Foundation
#if DEBUG
@testable import RTC
#else
import RTC
#endif
import Synchronization
import VADGate
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import RideIntercom

@MainActor
struct AudioE2EWaitingCall {
    let reference: CallReference
    let deadline: Date?

    init(viewModel: IntercomViewModel) {
        reference = viewModel.currentCallReference
        deadline = viewModel.callDisconnectDeadline
    }
}

private struct BackgroundQuietPeriod {
    let scenario: String
    let bothMute: Bool
    let keepMuted: Bool
}

extension AudioE2ETests {
    @MainActor
    func verifyWaitingParticipant(_ endpoint: AudioE2EEndpoint, waiting: AudioE2EWaitingCall) async throws {
        let viewModel = endpoint.viewModel
        let groupID = endpoint.run.groupID
        let mutedWait = endpoint.run.mutedWait
        let movesToBackground = endpoint.run.movesToBackground
        let transport = endpoint.run.transport
        try await waitUntil(
            seconds: 30, description: "The first endpoint has the route and native audio ready", status: endpoint.status
        ) {
            let routeReady = endpoint.run.usesInternet ? viewModel.availableCallRoutes == [.webRTC]
                : viewModel.localNetworkStatus == .advertisingBrowsing
            return routeReady && viewModel.isAudioReady
        }
        let waitingSince = ContinuousClock.now
        repeat {
            XCTAssertEqual(viewModel.activeGroupID, groupID)
            XCTAssertTrue(viewModel.authenticatedPeerIDs.isEmpty)
            XCTAssertFalse(viewModel.isCallMediaStarted)
            XCTAssertEqual(viewModel.sentVoicePacketCount, 0)
            if mutedWait > 0 {
                XCTAssertTrue(viewModel.effectiveInputMuted)
                XCTAssertTrue(viewModel.isAudioReady)
                XCTAssertEqual(viewModel.receivedVoicePacketCount, 0)
                XCTAssertEqual(viewModel.currentCallReference, waiting.reference)
                XCTAssertEqual(viewModel.callDisconnectDeadline, waiting.deadline)
            }
            checkBackgroundIfRequested(movesToBackground)
            try await Task.sleep(for: mutedWait > 0 ? .seconds(1) : .milliseconds(100))
        } while waitingSince.duration(to: .now) < .seconds(max(3, mutedWait))
        print(
            "Audio E2E: First endpoint waited on \(transport) alone with native audio active for "
                + "\(waitingSince.duration(to: .now)); muted=\(viewModel.effectiveInputMuted)"
        )
        let service = try XCTUnwrap(endpoint.worker.fixture)
        await service.markWaitingParticipantReady()
    }

    @MainActor
    func verifyLateParticipant(
        _ pair: AudioE2EPair, routes: AudioE2ERouteFixture,
        waiting: AudioE2EWaitingCall, joiningStarted: ContinuousClock.Instant
    ) async throws {
        let run = pair.endpoint.run
        let viewModel = pair.endpoint.viewModel
        let trace = PairedAudioTrace()
        let pipeline = viewModel.audioPipeline
        let originalTransmit = pipeline.onTransmitPacket
        let originalReceive = viewModel.callSession.processReceivedAudio
        pipeline.onTransmitPacket = { packet in
            trace.transmitted.withLock { $0.append(PacketTiming(packet)) }
            originalTransmit?(packet)
        }
        // Install once. Assigning processReceivedAudio replaces the media
        // subscription, so do not rebind it at measurement boundaries.
        viewModel.callSession.processReceivedAudio = tracedAudioReception(pipeline: pipeline, observe: { frame, entry in
            trace.received.withLock { $0.append(entry) }
            trace.decoded.append(frame, preservingTimeline: true)
        })
        defer {
            pipeline.onTransmitPacket = originalTransmit
            viewModel.callSession.processReceivedAudio = originalReceive
        }
        XCTAssertEqual(viewModel.availableCallRoutes, [run.soleRoute])
        XCTAssertEqual(viewModel.activeGroupID, run.groupID)
        print("Audio E2E: Authenticated remote over \(run.transport) after \(joiningStarted.duration(to: .now))")
        try await verifyPairedAudio(pair, trace: trace, expectation: .init(
            scenario: run.usesInternet ? "late-internet" : "late-local", movesToBackground: run.movesToBackground,
            expectsRemoteSpeech: run.mutedWait == 0 || run.role == "a"
        ))
        if run.checksBackgroundSilence || run.checksBackgroundMute {
            try await verifyBackgroundQuietAndResumedAudio(pair, trace: trace)
        }
        if run.checksInternetRecovery {
            try await verifyBackgroundInternetRecovery(pair)
        }
        #if DEBUG
        if run.checksLocalRecovery {
            try await verifyBackgroundLocalRecovery(pair, routes: XCTUnwrap(routes.instrumentedRoutes),
                                                    expectsMediaDuringRecovery: !run.checksBackgroundMute)
        }
        #endif
        if run.recovery {
            try await verifyMediaAfterRecovery(pair, trace: trace, waiting: waiting)
        }
        if run.mutedWait > 0 {
            XCTAssertEqual(viewModel.currentCallReference, waiting.reference)
            XCTAssertEqual(viewModel.callDisconnectDeadline, waiting.deadline)
            XCTAssertEqual(viewModel.effectiveInputMuted, run.role == "a")
        }
    }

    @MainActor
    private func verifyBackgroundQuietAndResumedAudio(_ pair: AudioE2EPair, trace: PairedAudioTrace) async throws {
        let run = pair.endpoint.run
        let scenario = run.checksBackgroundMute ? "background-mic-off" : "background-silence"
        try await verifyBackgroundQuietPeriod(pair, quiet: .init(
            scenario: scenario, bothMute: run.checksBackgroundMute, keepMuted: run.recovery
        ))
        if !run.recovery {
            try await verifyPairedAudio(pair, trace: trace, expectation: .init(
                scenario: "\(scenario)-resumed", movesToBackground: true,
                expectsRemoteSpeech: !run.checksBackgroundMute || run.role == "a"
            ))
            if run.checksBackgroundMute {
                XCTAssertEqual(pair.endpoint.viewModel.effectiveInputMuted, run.role == "a")
            }
        }
    }

    @MainActor
    private func verifyMediaAfterRecovery(
        _ pair: AudioE2EPair, trace: PairedAudioTrace, waiting: AudioE2EWaitingCall
    ) async throws {
        let run = pair.endpoint.run
        let viewModel = pair.endpoint.viewModel
        if run.checksBackgroundMute {
            XCTAssertTrue(viewModel.effectiveInputMuted)
            if run.role == "b" { XCTAssertTrue(viewModel.setCallMuted(false, for: waiting.reference)) }
        }
        try await verifyPairedAudio(pair, trace: trace, expectation: .init(
            scenario: run.checksInternetRecovery ? "background-internet-recovered" : "background-local-recovered",
            movesToBackground: true, expectsRemoteSpeech: !run.checksBackgroundMute || run.role == "a"
        ))
    }

    @MainActor
    func leaveForSettingsAfterStartingCall(
        viewModel: IntercomViewModel, joiningStarted: ContinuousClock.Instant
    ) async throws {
        #if os(iOS)
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        let settings = try XCTUnwrap(URL(string: UIApplication.openSettingsURLString))
        let wasAudioReady = viewModel.isAudioReady
        let opened = await UIApplication.shared.open(settings)
        XCTAssertTrue(opened)
        try await waitUntil(
            seconds: 5, description: "Settings brings the call application into the OS background",
            status: { "state=\(UIApplication.shared.applicationState.rawValue)" },
            condition: {
                UIApplication.shared.applicationState == .background
            }
        )
        print(
            "Audio E2E: Entered OS background after \(joiningStarted.duration(to: .now)); "
                + "audio ready before opening Settings=\(wasAudioReady)"
        )
        #else
        throw NSError(domain: "AudioE2E.BackgroundAfterStartRequiresIOS", code: 1)
        #endif
    }

    @MainActor
    func checkBackgroundIfRequested(_ requested: Bool) {
        #if os(iOS)
        if requested { XCTAssertEqual(UIApplication.shared.applicationState, .background) }
        #endif
    }

    @MainActor
    private func verifyBackgroundQuietPeriod(
        _ pair: AudioE2EPair, quiet: BackgroundQuietPeriod
    ) async throws {
        let viewModel = pair.endpoint.viewModel
        let barrier = pair.barrier
        let input = pair.endpoint.audio.input
        let probe = pair.endpoint.audio.probe
        let role = pair.endpoint.run.role
        let transport = pair.endpoint.run.transport
        let scenario = quiet.scenario
        let bothMute = quiet.bothMute
        checkBackgroundIfRequested(true)
        let call = viewModel.currentCallReference
        let callDeadline = viewModel.callDisconnectDeadline
        if bothMute { XCTAssertTrue(viewModel.setCallMuted(true, for: call)) } else { input.setSilentInput(true) }
        defer { if !bothMute { input.setSilentInput(false) } }
        try await barrier.meet("\(scenario)-input")
        try await Task.sleep(for: .seconds(1)) // Let VAD release and buffers drain.
        probe.reset()
        let firstSent = viewModel.sentVoicePacketCount
        let firstReceived = viewModel.receivedVoicePacketCount
        let firstOutputBatchCount = observedOutputBatches(viewModel)
        let started = ProcessInfo.processInfo.systemUptime
        try await waitThroughBackgroundQuietPeriod(pair, bothMute: bothMute, started: started)
        checkBackgroundIfRequested(true)
        let duration = ProcessInfo.processInfo.systemUptime - started
        let rendered = probe.snapshot()
        let transmitted = viewModel.sentVoicePacketCount - firstSent
        let received = viewModel.receivedVoicePacketCount - firstReceived
        let outputBatches = observedOutputBatches(viewModel) - firstOutputBatchCount
        let peak = await Task.detached {
            rendered.samples.reduce(Float(0)) { max($0, abs($1)) }
        }.value
        XCTAssertEqual(viewModel.callDisconnectDeadline, callDeadline)
        XCTAssertEqual(rendered.invalid, 0)
        XCTAssertLessThan(peak, 0.001, "The actual render must stay silent during \(scenario)")
        if bothMute {
            XCTAssertEqual(transmitted, 0)
            XCTAssertEqual(received, 0)
        }
        let evidence: [String: Any] = ["scenario": scenario, "background": true, "bothMicrophonesMuted": bothMute,
            "role": role, "transport": transport, "durationSeconds": duration, "peak": peak,
            "renderedSamples": rendered.samples.count, "renderedRate": rendered.rate,
            "transmitted": transmitted, "received": received, "outputBatches": outputBatches]
        try addAudioE2EJSONAttachment(evidence, name: "endpoint-\(role)-\(scenario)-measurement")
        try await barrier.meet("\(scenario)-observed")
        if bothMute, !quiet.keepMuted, role == "b" { XCTAssertTrue(viewModel.setCallMuted(false, for: call)) }
        print(
            "Audio E2E: Both endpoints kept the call during \(duration) seconds in \(scenario); "
                + "peak=\(peak) tx=\(transmitted) rx=\(received) outputBatches=\(outputBatches)"
        )
    }

    @MainActor
    private func verifyBackgroundInternetRecovery(
        _ pair: AudioE2EPair
    ) async throws {
        let endpoint = pair.endpoint
        let viewModel = endpoint.viewModel
        let run = endpoint.run
        let workerURL = try XCTUnwrap(endpoint.worker.url)
        let groupID = run.groupID
        let peerID = pair.peerID
        func signalOutage(_ phase: String) async throws {
            try await AudioE2EWorker.signalInternetOutage(
                phase, at: workerURL, room: endpoint.worker.room, token: run.identifier, participantID: run.memberID
            )
        }
        func status() -> String {
            "routes=\(viewModel.availableCallRoutes) state=\(viewModel.connectionState) "
                + "peers=\(viewModel.authenticatedPeerIDs.count) audioReady=\(viewModel.isAudioReady)"
        }
        checkBackgroundIfRequested(true)
        let callDeadline = viewModel.callDisconnectDeadline
        try await signalOutage("ready")
        try await waitUntil(
            seconds: 25, description: "The Internet route and authenticated peer are lost in the background",
            status: status
        ) {
            viewModel.availableCallRoutes.isEmpty && viewModel.authenticatedPeerIDs.isEmpty
        }
        let outageObserved = ContinuousClock.now
        let packetsAtLoss = viewModel.receivedVoicePacketCount
        repeat {
            checkBackgroundIfRequested(true)
            XCTAssertEqual(viewModel.activeGroupID, groupID)
            XCTAssertTrue(viewModel.availableCallRoutes.isEmpty)
            XCTAssertTrue(viewModel.isAudioReady)
            XCTAssertEqual(viewModel.receivedVoicePacketCount, packetsAtLoss)
            try await Task.sleep(for: .milliseconds(100))
        } while outageObserved.duration(to: .now) < .seconds(2)
        print("Audio E2E: Observed Internet route loss without stopping native audio or leaving the background")
        try await signalOutage("observed")
        try await waitUntil(
            seconds: 45, description: "The same call recovers its authenticated peer and media in the background",
            status: status
        ) {
            viewModel.availableCallRoutes == [.webRTC] && viewModel.authenticatedPeerIDs == [peerID]
                && viewModel.isCallMediaStarted && viewModel.isAudioReady
                && IntercomViewModel.admittedMemberships(in: viewModel.peerProfiles).count == 1
        }
        checkBackgroundIfRequested(true)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        XCTAssertEqual(viewModel.callDisconnectDeadline, callDeadline)
        let elapsed = outageObserved.duration(to: .now)
        print("Audio E2E: Recovered authenticated Internet media in the background after \(elapsed)")
    }

    #if DEBUG
    @MainActor
    private func verifyBackgroundLocalRecovery(
        _ pair: AudioE2EPair, routes: MixedRouteAudioE2E, expectsMediaDuringRecovery: Bool
    ) async throws {
        let viewModel = pair.endpoint.viewModel
        let barrier = pair.barrier
        let peerID = pair.peerID
        let groupID = pair.endpoint.run.groupID
        let callDeadline = viewModel.callDisconnectDeadline
        let oldMedia = try await routes.currentLocalMedia()
        try await barrier.meet("before-local-listener-loss")
        checkBackgroundIfRequested(true)
        let outageStarted = ContinuousClock.now
        try oldMedia.synchronized {
            let listenerFailed = try XCTUnwrap(oldMedia.onFailure)
            oldMedia.stop()
            listenerFailed("Local UDP listener interrupted by the audio E2E fixture")
        }
        XCTAssertNil(oldMedia.port)
        try await waitUntil(
            seconds: 2, description: "The Local route drops in the background",
            status: { viewModel.routeLabel },
            condition: {
                viewModel.availableCallRoutes.isEmpty
            }
        )
        try await Task.sleep(for: .milliseconds(200))
        let packetsAtLoss = viewModel.receivedVoicePacketCount
        try await Task.sleep(for: .milliseconds(500))
        checkBackgroundIfRequested(true)
        XCTAssertTrue(viewModel.availableCallRoutes.isEmpty)
        XCTAssertTrue(viewModel.isAudioReady)
        XCTAssertEqual(viewModel.receivedVoicePacketCount, packetsAtLoss)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        print("Audio E2E: Observed Local listener loss without leaving the background")

        try await waitUntil(
            seconds: 20, description: "The same call regains its Local route in the background",
            status: { viewModel.routeLabel },
            condition: {
                viewModel.availableCallRoutes == [.multipeer] && viewModel.authenticatedPeerIDs == [peerID]
                    && viewModel.isAudioReady && viewModel.isCallMediaStarted
            }
        )
        try await verifyReplacementListener(pair, routes: routes, replacing: oldMedia,
                                            expectsMediaDuringRecovery: expectsMediaDuringRecovery)
        checkBackgroundIfRequested(true)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        XCTAssertEqual(viewModel.callDisconnectDeadline, callDeadline)
        let elapsed = outageStarted.duration(to: .now)
        print("Audio E2E: Recovered Local media with a new listener in the background after \(elapsed)")
    }

    @MainActor
    private func verifyReplacementListener(
        _ pair: AudioE2EPair, routes: MixedRouteAudioE2E, replacing oldMedia: LocalDatagramTransport,
        expectsMediaDuringRecovery: Bool
    ) async throws {
        let viewModel = pair.endpoint.viewModel
        let peerID = pair.peerID
        let replacement = try await routes.currentLocalMedia()
        XCTAssertFalse(replacement === oldMedia)
        let peer = PeerID(rawValue: peerID)
        try await waitUntil(
            seconds: 10, description: "Replacement Local UDP is ready",
            status: { viewModel.routeLabel },
            condition: {
                replacement.isReady(for: peer)
                    && (!expectsMediaDuringRecovery || (replacement.statistics.receivedMediaDatagrams ?? 0) > 0)
            }
        )
    }
    #endif

    @MainActor
    private func waitThroughBackgroundQuietPeriod(
        _ pair: AudioE2EPair, bothMute: Bool, started: Double
    ) async throws {
        let viewModel = pair.endpoint.viewModel
        let peerID = pair.peerID
        let groupID = pair.endpoint.run.groupID
        let route = pair.endpoint.run.soleRoute
        repeat {
            checkBackgroundIfRequested(true)
            XCTAssertEqual(viewModel.activeGroupID, groupID)
            XCTAssertEqual(viewModel.availableCallRoutes, [route])
            XCTAssertEqual(viewModel.authenticatedPeerIDs, [peerID])
            XCTAssertTrue(viewModel.isAudioReady)
            XCTAssertTrue(viewModel.isCallMediaStarted)
            if bothMute {
                XCTAssertTrue(viewModel.effectiveInputMuted)
            } else {
                XCTAssertEqual(viewModel.audioPipeline.vadRuntimeSnapshot.state, .silence)
            }
            try await Task.sleep(for: .seconds(1))
        } while ProcessInfo.processInfo.systemUptime - started < 60
    }
}
