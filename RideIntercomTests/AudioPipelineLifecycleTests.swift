import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import Synchronization
import Testing
import VADGate

@testable import RideIntercom

extension AppTests.AudioPipelineTests {
    @Test func transmitProcessingPreservesCaptureClockWithoutPlaybackReservations() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        let collected = Mutex<[RTC.RTCAudioPacket]>([])
        pipeline.onTransmitPacket = { packet in collected.withLock { $0.append(packet) } }
        try pipeline.rebuild(
            configuration: .init(preferredCodec: .pcm16, transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        for sequence in 0..<2 {
            try pipeline.processCapturedFrame(
                .init(
                    sequenceNumber: UInt64(sequence), format: .intercomMixer, capturedAt: Double(sequence) * 0.1,
                    samples: Array(repeating: 0.03, count: 4800)))
            #expect(
                collected.withLock { $0.count } == (sequence + 1) * 10,
                "Encoding finishes before capture processing returns")
            try await Task.sleep(for: .milliseconds(50))
        }
        let packets = collected.withLock { $0 }
        #expect(packets.map(\.sequenceNumber) == Array(0..<20).map(UInt64.init))
        for (index, packet) in packets.enumerated() {
            #expect(abs(packet.capturedAt - Double(index) * 0.01) < 1.0 / 48000)
            #expect(packet.sampleCount == 480)
        }
        let source = try #require(pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sources.first)
        #expect(source.typeName == "AVAudioSourceNode")
        #expect(source.bufferedDuration == nil)
    }

    @Test func liveCallBoundsPCMReservationsWithoutRebuildingEffects() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        defer { harness.viewModel.disconnect() }
        let engines = harness.audioDriver.createdEngineCount
        #expect(harness.outputBackend.configurations.last?.maximumBufferedDuration == 0.2)
        for sequence in 0..<20 {
            let frame = PCMFrame(
                sequenceNumber: UInt64(sequence), format: .intercomMixer, capturedAt: 0,
                samples: Array(repeating: 0.2, count: 960))
            harness.callSession.receive(
                try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        }
        let peer = try #require(
            harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-peer-member-108" }?.sources.first)
        #expect((peer.bufferedDuration ?? 1) <= 0.22 + 1 / 48000.0)
        #expect(peer.playbackResetCount > 0)
        #expect(harness.audioDriver.createdEngineCount == engines)
    }

    @Test func frameDeliveryBoundsWaitingAudioAndCancelsWithoutLateCallbacks() async {
        var received: [UInt64] = []
        let delivery = AudioFrameDelivery { received.append($0.sequenceNumber) }
        for index in 0..<1000 {
            delivery.yield(PCMFrame(sequenceNumber: UInt64(index), format: .intercomMixer, capturedAt: 0, samples: [0]))
        }
        await AppTestSupport.waitUntil { received.count == 32 }
        #expect(received == Array(968..<1000).map(UInt64.init))
        delivery.yield(PCMFrame(sequenceNumber: 1000, format: .intercomMixer, capturedAt: 0, samples: [0]))
        delivery.finish()
        await Task.yield()
        #expect(received.last == 999)
    }

    @Test func microphoneObservationsCoalesceBeforeReachingTheUI() async throws {
        var received: [UInt64] = []
        let delivery = AudioFrameDelivery(coalescesObservations: true) { received.append($0.sequenceNumber) }
        defer { delivery.finish() }
        for index in 0..<1000 { delivery.yield(.init(sequenceNumber: UInt64(index), samples: [0.1])) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(received.count == 1, "Already-processed PCM must not create a UI callback per capture block")
        #expect(delivery.droppedFrameCount == 0, "Coalesced UI snapshots are not discarded media")
        try await Task.sleep(for: .milliseconds(50))
        delivery.yield(.init(sequenceNumber: 1000, samples: [0.2]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(received.last == 1000)
        #expect(received.count == 2)
    }

    @Test func captureObservationStartsOnlyWhenMediaIsReadyAndCannotReviveAfterStop() async {
        var received: [UInt64] = []
        let delivery = AudioFrameDelivery(initiallyActive: false) { received.append($0.sequenceNumber) }
        #expect(!delivery.isActive)
        for sequence in 0..<1000 {
            delivery.yield(.init(sequenceNumber: UInt64(sequence), capturedAt: 0, samples: [0]))
        }
        delivery.activate()
        #expect(delivery.isActive)
        delivery.yield(.init(sequenceNumber: 1000, capturedAt: 0, samples: [0.2]))
        await AppTestSupport.waitUntil { !received.isEmpty }
        #expect(received == [1000], "Initialization must not accumulate a stale UI backlog")
        #expect(delivery.droppedFrameCount == 0)
        delivery.finish()
        delivery.activate()
        #expect(!delivery.isActive)
        delivery.yield(.init(sequenceNumber: 1001, capturedAt: 0, samples: [0.2]))
        await Task.yield()
        #expect(received == [1000])
    }

    @Test func internetUsesSharedCaptureMixerAndDeviceRestart() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.setRTCTransportRoute(.multipeer, enabled: false)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.audioDriver.createdEngineCount == 1)
        #expect(!harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        let starts = harness.outputBackend.startCount
        harness.viewModel.refreshAudioDevicesIfNeeded()
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.outputBackend.startCount == starts + 1)
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func routeChangesPreservePeerVolumesAndEffectInstances() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.setRemoteOutputVolume(peerID: "member-108", volume: 0.25)
        harness.viewModel.setRemoteSoundIsolationEnabled(peerID: "member-108", enabled: true)
        harness.viewModel.setMasterOutputVolume(0.75)
        let engines = harness.audioDriver.createdEngineCount
        let before = harness.viewModel.audioPipeline.snapshot
        for routes: Set<RTC.RouteKind> in [[.webRTC], [.webRTC, .multipeer], [.multipeer]] {
            harness.viewModel.handleTransportEvent(
                .routesChanged(
                    .init(
                        activeRoute: routes.contains(.webRTC) ? .webRTC : .multipeer, mediaRoute: nil,
                        availableRoutes: routes, isHandoverInProgress: false)))
            #expect(harness.viewModel.audioPipeline.snapshot == before)
            #expect(harness.viewModel.remoteOutputVolumes["member-108"] == 0.25)
            #expect(harness.audioDriver.createdEngineCount == engines)
        }
        harness.viewModel.disconnect()
    }

    @Test func connectingCancelsAudioCheckBeforePeerAuthentication() {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .preparing)
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        #expect(harness.viewModel.audioCheckPhase == .idle)
        #expect(!harness.viewModel.audioCheckOwnsAudioPipeline)
        harness.viewModel.startAudioCheck()
        #expect(harness.viewModel.audioCheckPhase == .idle)
        harness.viewModel.disconnect()
    }

    @Test func mixedRoutesKeepEffectsAndPacketAudioOwnership() async {
        let rtc = FakeRTCCallSession()
        let adapter = RideIntercomCallSessionAdapter(rtcSession: rtc)
        await AppTestSupport.waitUntil { rtc.hasSubscriber }
        rtc.emit(
            .routeChanged(
                .init(
                    activeRoute: .webRTC, mediaRoute: .webRTC, availableRoutes: [.webRTC, .multipeer],
                    isHandoverInProgress: false)))
        await AppTestSupport.waitUntil { adapter.activeRouteDebugTypeName.contains("WebRTC") }
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let starts = harness.inputBackend.startCount
        harness.viewModel.handleTransportEvent(
            .routesChanged(
                .init(
                    activeRoute: .webRTC, mediaRoute: .webRTC, availableRoutes: [.webRTC, .multipeer],
                    isHandoverInProgress: false)))
        #expect(harness.viewModel.routeLabel == "Local + Internet / Relay")
        #expect(harness.inputBackend.startCount == starts)
        harness.viewModel.handleTransportEvent(
            .routesChanged(
                .init(
                    activeRoute: .multipeer, mediaRoute: .multipeer, availableRoutes: [.multipeer],
                    isHandoverInProgress: false)))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.inputBackend.startCount == starts)
        harness.viewModel.handleTransportEvent(
            .routesChanged(
                .init(
                    activeRoute: .webRTC, mediaRoute: .webRTC, availableRoutes: [.webRTC], isHandoverInProgress: false))
        )
        #expect(harness.viewModel.connectionState == .internetConnected)
        #expect(harness.viewModel.callPresenceLabel == CallConnectionState.internetConnected.label)
        #expect(harness.viewModel.routeLabel == "Internet")
        #expect(harness.inputBackend.startCount == starts)
        harness.viewModel.disconnect()
    }

    @Test func departedPeerReleasesAudioGraphAndRemoteClockCannotHoldTalkingState() async throws {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(harness.viewModel.groups[0])
        harness.callSession.authenticate(["member-108", "member-215"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let format = AudioFormat.intercomPacketAudio
        let future = Date().timeIntervalSince1970 + 86400
        let frame = PCMFrame(
            sequenceNumber: 1, format: format, capturedAt: future, samples: Array(repeating: 0.1, count: 480))
        harness.callSession.receive(
            try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
        #expect((try #require(harness.viewModel.remoteVoiceReceivedAt["member-108"])) < future - 1000)
        harness.viewModel.removeDisconnectedAuthenticatedPeers(connectedPeerIDs: ["member-215"])
        #expect(!harness.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-108"))
        #expect(harness.viewModel.audioPipeline.snapshot.busIDs.contains("rx-peer-member-215"))
    }

    @Test(arguments: [960, 4800]) func vadPrerollTracksAttackTimeInsteadOfHardwareFrameCount(count: Int) {
        var controller = AudioTransmissionController(
            vadGate: VADGate(
                configuration: .init(
                    attackDuration: 0.08, releaseDuration: 0.05, speechThresholdOffsetDB: 6, initialNoiseFloorDBFS: -60)
            ))
        func frame(_ id: UInt64, sample: Float) -> PCMFrame {
            .init(
                sequenceNumber: id, format: .intercomPacketAudio, capturedAt: Double(id) * Double(count) / 48000,
                samples: Array(repeating: sample, count: count))
        }
        for id in 0..<30 { _ = controller.process(frame: frame(UInt64(id), sample: 0), level: 0) }
        let attackFrames = Int(ceil(0.08 / (Double(count) / 48000)))
        var emitted: [PCMFrame] = []
        for index in 0..<(attackFrames * 2) {
            let value: Float = index < attackFrames ? 0.4 : 0
            emitted += controller.process(frame: frame(UInt64(30 + index), sample: value), level: value).compactMap {
                if case .voice(let frame) = $0 { frame } else { nil }
            }
        }
        let expected: [UInt64] = count == 960 ? Array(30...34) : [30]
        #expect(
            emitted.map(\.sequenceNumber) == expected,
            "Preserve the onset and hangover once, without retaining already classified silence before the attack")
        #expect(
            emitted.filter { $0.samples.contains { $0 > 0 } }.count == attackFrames,
            "Preserve every onset frame while excluding old silence")
    }

    @Test func vadUsesCapturedDurationAndDoesNotReplayOldPreroll() {
        var controller = AudioTransmissionController(
            vadGate: VADGate(
                configuration: .init(
                    attackDuration: 0.08, releaseDuration: 0.05, speechThresholdOffsetDB: 6, initialNoiseFloorDBFS: -60)
            ), preRollLimit: 2)
        func frame(_ id: UInt64, sample: Float, count: Int) -> PCMFrame {
            let precedingFrames = id < 10 ? Int(id) * 128 : 10 * 128 + Int(id - 10) * 4800
            return .init(
                sequenceNumber: id, format: .intercomPacketAudio, capturedAt: Double(precedingFrames) / 48_000,
                samples: Array(repeating: sample, count: count))
        }
        for id in 0..<10 {
            #expect(
                controller.process(frame: frame(UInt64(id), sample: 0.5, count: 128), level: 0.5).allSatisfy {
                    if case .silence(let value) = $0 { value.samples.allSatisfy { $0 == 0 } } else { false }
                })
        }
        let speech = controller.process(frame: frame(10, sample: 0.5, count: 4800), level: 0.5)
        #expect(!speech.isEmpty)
        _ = controller.process(frame: frame(11, sample: 0, count: 4800), level: 0)
        let next = controller.process(frame: frame(12, sample: 0.5, count: 4800), level: 0.5)
        #expect(next == [.voice(frame(12, sample: 0.5, count: 4800))])
        #expect(
            controller.process(frame: frame(13, sample: 0, count: 4800), level: 0) == [
                .silence(frame(13, sample: 0, count: 4800))
            ])
    }

}
