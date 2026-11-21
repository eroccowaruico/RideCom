import AudioCore
import AudioMixer
import AVFAudio
import Codec
import Foundation
import RTC
import SoundIsolation
import Synchronization
import Testing
import VADGate
@testable import RideIntercom

extension AppTests {
@MainActor
struct RealtimeConversationTests {
    @Test func callReceiveWindowBoundsStartupAndLearnsWiFiJitter() {
        let window = AppAudioPipelineConfiguration.callReceiveMaximumBufferedDuration
        let start = AppAudioPipelineConfiguration.callReceivePlayoutDelay
        // Audio queued before the output clock runs is rebuilt beyond the
        // window: a wider window keeps that start-up delay for the whole call.
        #expect(window <= 0.12)
        // AudioMixer learns up to half of the window minus the start wait.
        #expect((window - start) / 2 >= 0.05, "Learns at least 50 ms of extra Wi-Fi transit")
        #expect(start <= 0.002, "A calm link keeps the low-delay start")
    }

    @Test func receiverForwardsCodecCadenceWithoutCodecSpecificPlaybackBranches() throws {
        let engine = AVAudioEngine()
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: native, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["cadence"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let format = AudioFormat(sampleRate: 16000, channelCount: 1)
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format))
        for i in 0..<8 {
            guard let encoded = try encoder.encode(.init(sequenceNumber: UInt64(i), format: format,
                capturedAt: Double(i) * 0.02, samples: Array(repeating: 0.1, count: 320))) else { continue }
            let frame = try receiver.receive(.init(peerID: .init(rawValue: "cadence"), packet: .init(
                sequenceNumber: encoded.sequenceNumber, codec: .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1),
                capturedAt: encoded.capturedAt, sampleCount: encoded.sampleCount, payload: encoded.payload)))
            if !frame.samples.isEmpty {
                let state = try #require(receiver.playoutDiagnostics(peer: "cadence"))
                let margin = state.bufferedDuration - Double(frame.frameCount) / 16000
                #expect(abs(margin - 0.012) < 3 / 48000.0)
                #expect(state.adjustments == 0 && state.resets == 0)
                return
            }
        }
        Issue.record("AAC never produced a decoded frame")
    }

    @Test func receiveWaitingBehindStopCannotEnterTheRebuiltGraph() throws {
        let receiver = AppAudioReceiver()
        let driver = OfflineAudioDriver()
        let config = AppAudioPipelineConfiguration(transmitSoundIsolationEnabled: false)
        try receiver.rebuild(engine: driver.makeEngine(), configuration: config, peers: [],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        // Hold the real owner lock to reproduce an already-arrived packet
        // waiting behind a lifecycle change, without adding production hooks.
        let lock = try #require(Mirror(reflecting: receiver).children.first { $0.label == "lock" }?.value as? NSRecursiveLock)
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "old-call",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let rejected = Mutex(false)
        lock.lock()
        var held = true
        defer { if held { lock.unlock() } }
        DispatchQueue.global(qos: .userInteractive).async {
            entered.signal()
                do { _ = try receiver.receive(packet) } catch AppAudioPipelineError.notConfigured {
                    rejected.withLock { $0 = true }
                } catch {}
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
        receiver.stop()
        try receiver.rebuild(engine: driver.makeEngine(), configuration: config, peers: [],
            rendersToHardware: false, onOutput: { _ in })
        lock.unlock(); held = false
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(rejected.withLock { $0 })
        #expect(!receiver.snapshot.busIDs.contains("rx-peer-old-call"))
    }

    @Test(arguments: [false, true])
    func receiveLearnsLinkDelayWithoutLearningTimeSpentWaitingForTheGraph(lateArrival: Bool) throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["peer"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        func packet(_ number: UInt64, at capture: TimeInterval) throws -> RTC.ReceivedAudioPacket {
            try AppTestSupport.receivedAudioPacket(peerID: "peer",
                frame: .init(sequenceNumber: number, capturedAt: capture, samples: Array(repeating: 0.2, count: 480)),
                codec: .pcm16)
        }
        _ = try receiver.receive(packet(0, at: ProcessInfo.processInfo.systemUptime))
        #expect(try engine.renderOffline(4800, to: output) == .success)
        let capture = ProcessInfo.processInfo.systemUptime + 0.01
        let delayed = try packet(1, at: capture)
        while ProcessInfo.processInfo.systemUptime < capture { Thread.sleep(forTimeInterval: 0.001) }
        if lateArrival {
            Thread.sleep(forTimeInterval: 0.06)
            _ = try receiver.receive(delayed)
        } else {
            // The packet has already reached the App while the graph owner is busy.
            let lock = try #require(Mirror(reflecting: receiver).children.first { $0.label == "lock" }?.value as? NSRecursiveLock)
            let started = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            let decoded = Mutex(false)
            lock.lock()
            DispatchQueue.global(qos: .userInteractive).async {
                started.signal()
                decoded.withLock { $0 = (try? receiver.receive(delayed)) != nil }
                completed.signal()
            }
            let entered = started.wait(timeout: .now() + 1)
            let waited = completed.wait(timeout: .now() + .milliseconds(60))
            lock.unlock()
            #expect(entered == .success && waited == .timedOut)
            #expect(completed.wait(timeout: .now() + 1) == .success)
            #expect(decoded.withLock { $0 })
        }
        #expect(receiver.playoutDiagnostics(peer: "peer")?.adjustments == 1)
        // Drain the rebooked voice so the next reservation shows only the retained allowance.
        #expect(try engine.renderOffline(4800, to: output) == .success)
        _ = try receiver.receive(packet(2, at: capture + 1))
        let buffered = try #require(receiver.playoutDiagnostics(peer: "peer")?.bufferedDuration)
        if lateArrival {
            #expect(buffered >= 0.05)
        } else {
            #expect(buffered <= 0.035)
        }
    }

    @Test func receiverReportsTheAdjustmentOnlyForThePacketThatMoved() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.02), peers: ["peer"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        let start = ProcessInfo.processInfo.systemUptime
        var observed: [ReceivePlayoutDiagnostics] = []
        func receive(_ sequence: UInt64) throws {
            let frame = PCMFrame(sequenceNumber: sequence, capturedAt: start + Double(sequence) * 0.02,
                samples: Array(repeating: 0.2, count: 960))
            let received = try AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16)
            _ = try receiver.receive(received, onPlayout: { observed.append($0) })
        }
        try receive(0)
        #expect(try engine.renderOffline(2400, to: output) == .success)
        try receive(1)
        try receive(2)
        #expect(observed.map(\.adjustments) == [0, 1, 1])
        #expect(observed.map { $0.adjustment?.reason } == [nil, .pastRenderPosition, nil])
        #expect(observed[1].adjustment?.capturedAt == start + 0.02)
        for packet in observed {
            let timing = try #require(packet.processingTiming)
            let acquired = try #require(timing.lockAcquiredAt)
            let decoded = try #require(timing.decodedAt)
            let reserved = try #require(timing.reservedAt)
            #expect(start <= timing.lockRequestedAt)
            #expect(timing.lockRequestedAt <= acquired)
            #expect(acquired <= decoded)
            #expect(decoded <= reserved)
        }
        #expect(receiver.playoutDiagnostics(peer: "peer")?.processingTiming == nil)
    }

    @Test func preparedReceiverQueuesSpeechUntilGraphStart() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2400)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["peer"],
            rendersToHardware: true, startsClock: false, onOutput: { _ in })
        defer { receiver.stop() }

        let frame = PCMFrame(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 960))
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16)
        _ = try receiver.receive(packet)
        let player = try #require(engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        #expect(!player.isPlaying)
        #expect(!engine.isRunning)
        #expect(receiver.playoutDiagnostics(peer: "peer")?.bufferedDuration == 0.022)

        try receiver.start()
        #expect(player.isPlaying)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        #expect(try engine.renderOffline(2400, to: output) == .success)
        let samples = UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: Int(output.frameLength))
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func codecChangesFinishTheOldFadeAndCoalesceOnlySettings() throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(preferredCodec: .mpeg4AACELD, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<130 {
            if index == 100 {
                try transmitter.updateEncoding(.init(codec: .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1)))
                try transmitter.updateEncoding(.init(codec: .mpeg4AACELD, format: .init(sampleRate: 24000, channelCount: 1)))
            }
            try transmitter.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
                samples: (0..<480).map { Float(0.15 * sin(Double(index * 480 + $0) * 2 * .pi * 600 / 48000)) }))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.contains { $0.format.sampleRate == 16000 }, "Only the replaceable setting may coalesce")
        let firstNew = try #require(sent.firstIndex { $0.format.sampleRate == 24000 })
        #expect(firstNew > 0)
        #expect(sent[firstNew].capturedAt < 1.09)
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $1.sequenceNumber == $0.sequenceNumber + 1 })
        let decoder = StreamingCodecDecoder()
        var oldLast: PCMFrame?
        for packet in sent.prefix(firstNew) { oldLast = try AppAudioCodecBridge.decode(packet, using: decoder) }
        #expect(try #require(oldLast).samples.suffix(96).allSatisfy { abs($0) < 0.002 },
            "The already-sent old codec must finish its fade before the new codec fills its first packet")
        #expect(transmitter.failureCount == 0)
    }

    @Test(arguments: [RTCAudioCodecIdentifier.pcm16, .opus, .mpeg4AACELD])
    func silentTransmitterStopsPacketsAndRestartsForBriefReplies(codec: RTCAudioCodecIdentifier) throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(preferredCodec: codec, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<400 {
            let samples = (0..<480).map { sample in
                (200..<210).contains(index) ? Float(0.03 * sin(Double(sample) * 2 * .pi * 500 / 48000)) : 0
            }
            transmitter.processMicrophone(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.isEmpty)
        #expect(sent.count < 120, "Silence must avoid encoding and sending, including the VAD release period")
        #expect(sent.filter { (0.3..<1.9).contains($0.capturedAt) || (3..<4).contains($0.capturedAt) }.isEmpty)
        let onset = try #require(sent.first { $0.capturedAt >= 1.9 })
        #expect(onset.capturedAt < 2.03, "A 100 ms acknowledgement must resume immediately")
        #expect(transmitter.failureCount == 0)
    }

    @Test(arguments: [256, 480, 960])
    func transmitIsolationSwitchDoesNotClickWithoutNetworkOrHardware(quantum: Int) throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(transmitSoundIsolationEnabled: false)
        let received = Mutex<[Float]>([])
        let failures = Mutex<[String]>([])
        transmitter.onPacket = { packet in
            do {
                let frame = try AppAudioCodecBridge.decode(packet)
                received.withLock { $0 += frame.samples }
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        let framesPerStage = Int(48000 / quantum)
        for index in 0..<(framesPerStage * 4) {
            if index > 0, index.isMultiple(of: framesPerStage) {
                try transmitter.updateIsolation(enabled: (index / framesPerStage).isMultiple(of: 2) == false)
            }
            let offset = index * quantum
            try transmitter.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(offset) / 48000,
                samples: (0..<quantum).map { Float(0.15 * sin(Double(offset + $0) * 2 * .pi * 600 / 48000)) }))
        }
        let samples = received.withLock { $0 }
        #expect(failures.withLock { $0.isEmpty })
        #expect(samples.count >= framesPerStage * quantum * 4 - 480)
        let maximumStep = zip(samples.dropFirst(24000), samples.dropFirst(24001)).map { abs($0 - $1) }.max() ?? 1
        #expect(maximumStep < 0.04, "The transmitted waveform itself must fade; a local RX fade cannot protect remote listeners")
    }

    @Test func changingTransmitIsolationDoesNotSuspendReceiving() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let started = DispatchSemaphore(value: 0), finished = Mutex(false)
        defer { finished.withLock { $0 = true } }
        let task = Task.detached(priority: .userInitiated) {
            var failed = 0, received = 0
            started.signal()
            repeat {
                do { _ = try pipeline.processReceivedAudioPacket(packet); received += 1 } catch { failed += 1 }
                try? await Task.sleep(for: .milliseconds(1))
            } while !finished.withLock({ $0 })
            return (received, failed)
        }
        #expect(waitForAudioWhileUIIsOccupied(started))
        try pipeline.updateSoundIsolation(transmit: true, receiveMaster: false, peers: [:])
        finished.withLock { $0 = true }
        let result = await task.value
        #expect(result.0 > 0)
        #expect(result.1 == 0, "The independent transmit graph cannot suspend remote voice")
    }

    @Test func inputReconfigurationDiscardsIncomingAudioWithoutWaiting() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let completed = DispatchSemaphore(value: 0)
        let task = pipeline.reconfigureInput {
            let task = Task.detached(priority: .userInitiated) {
                let result = Result { try pipeline.processReceivedAudioPacket(packet) }
                completed.signal()
                return result
            }
            #expect(waitForAudioWhileUIIsOccupied(completed),
                "An I/O change must not queue speech behind the native reconfiguration")
            return task
        }
        let result = await task.value
        #expect(throws: AppAudioPipelineError.notConfigured) { try result.get() }
        #expect(pipeline.snapshot.buses.first { $0.id == "rx-peer-peer" }?.sources.first?.scheduledFrameCount == 0)
    }

    @Test func receiveIsolationRetainsItsNativeParametersAfterGraphChanges() throws {
        let driver = OfflineAudioDriver()
        let engine = driver.makeEngine()
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let effects = engine.attachedNodes.compactMap { $0 as? AVAudioUnitEffect }.filter {
            $0.audioComponentDescription.componentSubType == kAudioUnitSubType_AUSoundIsolation
        }
        try #require(effects.count == (VoiceIsolationSupport.isAvailable ? 2 : 0))
        for enabled in [true, false, true] {
            try pipeline.updateSoundIsolation(transmit: false, receiveMaster: enabled, peers: ["peer": enabled])
            for effect in effects {
                #expect(effect.bypass == !enabled)
                try effect.withAUAudioUnit { unit in
                    let parameters = try #require(unit.parameterTree)
                    #expect(parameters.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_SoundToIsolate))?.value
                        == AUValue(kAUSoundIsolationSoundType_Voice))
                    #expect(parameters.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?.value
                        == 50)
                }
            }
        }
    }

    @Test func receiveIsolationKeepsPeerIdentityAcrossRemovalAndRejoin() throws {
        try #require(VoiceIsolationSupport.isAvailable)
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["one", "rx-master"])
        defer { pipeline.stop() }

        try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: ["one": true, "late": true])
        #expect(pipeline.isolationRuntimeSnapshots["rx-master"]?.state == .bypassed)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-rx-master"]?.state == .bypassed)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-one"]?.state == .active)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-late"] == nil)

        try pipeline.stopReceivePeer("one")
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-one"] == nil)
        for peer in ["one", "late"] {
            let packet = try AppTestSupport.receivedAudioPacket(peerID: peer,
                frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
            _ = try pipeline.processReceivedAudioPacket(packet)
            #expect(pipeline.isolationRuntimeSnapshots["rx-peer-\(peer)"]?.state == .active)
        }

        try pipeline.updateSoundIsolation(transmit: false, receiveMaster: true, peers: ["rx-master": true])
        #expect(pipeline.isolationRuntimeSnapshots["rx-master"]?.state == .active)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-rx-master"]?.state == .active)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-one"]?.state == .bypassed)
        #expect(pipeline.isolationRuntimeSnapshots["rx-peer-late"]?.state == .bypassed)
    }

    @Test(arguments: [false, true])
    func stoppingOrMutingDiscardsPendingSpeech(mute: Bool) throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        pipeline.applyVADSensitivity(.noisy)
        for number in 0..<4 {
            pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(number),
                capturedAt: Double(number) * 0.005, samples: Array(repeating: 0.3, count: 240)))
        }
        #expect(pipeline.vadRuntimeSnapshot.state == .speech)
        if mute {
            let sent = pipeline.inputObservation.sentPackets
            let processed = pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sinks.first?.emittedFrameCount ?? 0
            pipeline.setInputMuted(true)
            for number in 4..<44 {
                pipeline.processMicrophoneFrame(.init(sequenceNumber: UInt64(number),
                    capturedAt: Double(number) * 0.005, samples: Array(repeating: 0.3, count: 240)))
            }
            #expect(pipeline.inputObservation.sentPackets == sent)
            #expect((pipeline.snapshot.buses.first { $0.id == "tx-bus" }?.sinks.first?.emittedFrameCount ?? 0) > processed,
                "Native DSP must consume silent time during mute instead of freezing an old speech tail")
            pipeline.setInputMuted(false)
        } else { pipeline.stop() }
        #expect(pipeline.vadRuntimeSnapshot.state == .silence,
            "A new unmuted capture/call must never inherit a previous speech window")
    }

    @Test(arguments: [0.005, 0.01, 0.02], VoiceActivitySensitivity.allCases)
    func vadHoldsOnlyTheAttackNotAlreadyCoveredByTheCurrentFrame(duration: Double, sensitivity: VoiceActivitySensitivity) {
        var controller = AudioTransmissionController()
        controller.applyVADSensitivity(sensitivity)
        let heldFrames = max(0, Int((sensitivity.configuration.attackDuration / duration).rounded()) - 1)
        var emitted: [UInt64] = []
        for index in 0..<20 {
            let frame = PCMFrame(sequenceNumber: UInt64(index), capturedAt: Double(index) * duration,
                samples: Array(repeating: 0.2, count: Int((48000 * duration).rounded())))
            let packets = controller.process(frame: frame, level: 0.2)
            for packet in packets {
                if case .voice(let voice) = packet { emitted.append(voice.sequenceNumber) }
            }
            #expect(emitted.count == max(0, index + 1 - heldFrames),
                "The current captured samples already contribute to VAD attack; do not wait another full frame")
        }
        #expect(emitted == (0..<emitted.count).map(UInt64.init), "No onset sample may be omitted or repeated")
    }

    @Test func cancelledRTCConsumerCannotScheduleIntoTheCurrentGraph() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let gate = ManualAsyncGate()
        let task = Task.detached {
            await gate.wait()
            return Result { try pipeline.processReceivedAudioPacket(packet) }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.release()
        let result = await task.value
        #expect(throws: AppAudioPipelineError.notConfigured) { try result.get() }
        let source = pipeline.snapshot.buses.first { $0.id == "rx-peer-peer" }?.sources.first
        #expect(source?.scheduledFrameCount == 0)
    }

    @Test func transmitDSPAndEncodingDoNotWaitForTheUIActor() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: [])
        defer { pipeline.stop() }
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            try pipeline.processCapturedFrame(.init(sequenceNumber: 0,
                samples: Array(repeating: 0.1, count: 480)))
            completion.signal()
        }
        #expect(waitForAudioWhileUIIsOccupied(completion),
            "Captured PCM must traverse DSP and encoding while UI/control is busy")
        _ = try await task.value
    }

    @Test func receiveDecodeAndScheduleDoNotWaitForTheUIActor() async throws {
        let driver = OfflineAudioDriver()
        let pipeline = AppAudioPipeline(makeEngine: driver.makeEngine)
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let completion = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .userInitiated) {
            try pipeline.processReceivedAudioPacket(packet)
            completion.signal()
        }
        #expect(waitForAudioWhileUIIsOccupied(completion),
            "Decoding and native playback scheduling must not wait for UI/control")
        _ = try await task.value
    }

    private func waitForAudioWhileUIIsOccupied(_ completion: DispatchSemaphore) -> Bool {
        completion.wait(timeout: .now() + .milliseconds(30)) == .success
    }

    @Test func transmitFormatChangeKeepsReceiveGraphRunning() throws {
        let driver = OfflineAudioDriver()
        let engine = driver.makeEngine()
        let pipeline = AppAudioPipeline(makeEngine: { engine })
        try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
        defer { pipeline.stop() }
        try pipeline.processPlaybackFrame(.init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)))
        let before = pipeline.snapshot
        let nodes = engine.attachedNodes
        try pipeline.updateEncoding(preferred: .opus, format: .init(sampleRate: 16000, channelCount: 1),
            aacELDv2BitRate: 32000, opusBitRate: 64000)
        #expect(pipeline.codecRuntimeReport.activeConfiguration.codec == .opus)
        #expect(pipeline.codecRuntimeReport.activeConfiguration.activeBitRate == 64000)
        let valid = pipeline.codecRuntimeReport.activeConfiguration
        var invalid = AudioFormat()
        invalid.sampleRate = .nan // Bypass the public initializer's normalization, as malformed decoded state can.
        #expect(throws: AppAudioPipelineError.invalidFormat) {
            try pipeline.updateEncoding(preferred: .mpeg4AACELD, format: invalid,
                aacELDv2BitRate: 48000, opusBitRate: 48000)
        }
        #expect(pipeline.codecRuntimeReport.activeConfiguration == valid,
            "Invalid configuration must not reach native converters or replace the accepted configuration")
        let after = pipeline.snapshot
        #expect(engine.isRunning)
        #expect(engine.attachedNodes == nodes)
        let receiveBefore = before.buses.filter { $0.id != "tx-bus" }
        var receiveAfter = after.buses.filter { $0.id != "tx-bus" }
        // The live render clock keeps consuming audio during a TX change.
        // Compare graph/configuration exactly, but require its counters to
        // advance instead of incorrectly requiring the output to stand still.
        for bus in receiveAfter.indices where receiveBefore.indices.contains(bus) {
            for source in receiveAfter[bus].sources.indices where receiveBefore[bus].sources.indices.contains(source) {
                #expect((receiveAfter[bus].sources[source].bufferedDuration ?? 0)
                    <= (receiveBefore[bus].sources[source].bufferedDuration ?? 0))
                receiveAfter[bus].sources[source].bufferedDuration = receiveBefore[bus].sources[source].bufferedDuration
            }
            for sink in receiveAfter[bus].sinks.indices where receiveBefore[bus].sinks.indices.contains(sink) {
                #expect(receiveAfter[bus].sinks[sink].emittedFrameCount >= receiveBefore[bus].sinks[sink].emittedFrameCount)
                receiveAfter[bus].sinks[sink].emittedFrameCount = receiveBefore[bus].sinks[sink].emittedFrameCount
                receiveAfter[bus].sinks[sink].normalizationReport = receiveBefore[bus].sinks[sink].normalizationReport
            }
        }
        #expect(receiveBefore == receiveAfter)
        #expect(after.buses.first { $0.id == "tx-bus" }?.sinks.first?.targetFormat.sampleRate == 16000)
    }

    @Test(arguments: VoiceActivitySensitivity.allCases)
    func shortAcknowledgementsStartWithinTwentyMilliseconds(sensitivity: VoiceActivitySensitivity) {
        var controller = AudioTransmissionController()
        controller.applyVADSensitivity(sensitivity)
        let starts = [200, 412, 824, 1436] // 1, 1, 2, 3 second pauses around 60 ms replies
        var sent: [UInt64] = []
        var sentAt: [UInt64: Int] = [:]
        var clock: [UInt64] = []
        for number in 0..<1600 {
            let audible = starts.contains { number >= $0 && number < $0 + 12 }
            let samples = (0..<240).map { audible ? Float(sin(Double(number * 240 + $0) * 2 * .pi * 440 / 48000) * 0.3) : 0 }
            let frame = PCMFrame(sequenceNumber: UInt64(number), capturedAt: Double(number) * 0.005, samples: samples)
            for packet in controller.process(frame: frame, level: audible ? 0.2 : 0) {
                if case .voice(let voice) = packet { sent.append(voice.sequenceNumber); sentAt[voice.sequenceNumber] = number }
                switch packet {
                case .voice(let frame), .silence(let frame): clock.append(frame.sequenceNumber)
                }
            }
        }
        #expect(clock == (0..<clock.count).map(UInt64.init), "Silence must preserve the codec clock without omission or replay")
        #expect(clock.count >= 1596, "Only the pending VAD attack window may remain buffered")
        for start in starts {
            for number in start..<(start + 12) {
                #expect(sent.filter { $0 == UInt64(number) }.count == 1,
                    "Every part of a brief acknowledgement must be sent exactly once")
            }
            #expect((sentAt[UInt64(start)] ?? 10000) - start <= 4,
                "VAD must not add more than 20 ms before the first phoneme")
        }
    }
}
}
