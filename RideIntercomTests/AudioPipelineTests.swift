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

extension AppTests {
    @MainActor struct AudioPipelineTests {
        @Test(arguments: [true, false])
        func defaultAACStopsSendingDuringQuietSteadyNoise(isolationEnabled: Bool) throws {
            let transmitter = AppAudioTransmitter()
            let format = AudioFormat.intercomMixer
            let configuration = AppAudioPipelineConfiguration(
                preferredCodec: IntercomViewModel.defaultTransmitCodec, transmitSoundIsolationEnabled: isolationEnabled)
            let encoding = configuration.codecRuntimeReport.activeConfiguration
            try transmitter.rebuild(configuration: configuration, encoding: encoding)
            defer { transmitter.stop() }
            let frameCount = 480
            func send(_ samples: [Float], index: Int) {
                transmitter.processMicrophone(.init(
                        sequenceNumber: UInt64(index), format: format,
                        capturedAt: Double(index * frameCount) / format.sampleRate, samples: samples))
            }

            for index in 0..<100 { send(Array(repeating: 0, count: frameCount), index: index) }
            for index in 100..<160 {
                send((0..<frameCount).map {
                        Float(0.1 * sin(Double(index * frameCount + $0) * 2 * .pi * 400 / format.sampleRate))
                    }, index: index)
            }
            #expect(transmitter.vadSnapshot.state == .speech)

            var seed: UInt32 = 1
            func sendNoise(_ range: Range<Int>) {
                for index in range {
                    let samples = (0..<frameCount).map { _ in
                        seed = 1_664_525 &* seed &+ 1_013_904_223
                        return (Float(seed >> 16) / 32_768 - 1) * Float(0.001)
                    }
                    send(samples, index: index)
                }
            }
            sendNoise(160..<360)
            let settled = transmitter.inputObservation.sentPackets
            sendNoise(360..<460)
            let analysis = try #require(transmitter.vadSnapshot.lastAnalysis)
            print(
                "Default AAC silence probe: isolation=\(isolationEnabled) state=\(analysis.state) "
                    + "applied=\(transmitter.isolationSnapshot?.state.rawValue ?? "unavailable") "
                    + "input=\(analysis.rmsDBFS)dBFS floor=\(analysis.noiseFloorDBFS)dBFS "
                    + "packetsInLastSecond=\(transmitter.inputObservation.sentPackets - settled)")
            #expect(analysis.state == .silence)
            #expect(transmitter.inputObservation.sentPackets == settled)

            for index in 460..<472 {
                send((0..<frameCount).map {
                        Float(0.02 * sin(Double(index * frameCount + $0) * 2 * .pi * 330 / format.sampleRate))
                    }, index: index)
            }
            #expect(transmitter.vadSnapshot.state == .speech)
            sendNoise(472..<502)
            #expect(transmitter.inputObservation.sentPackets > settled)
            #expect(transmitter.failureCount == 0)
        }

        @Test func receiveGraphUsesDeviceClockWithoutImplicitOutputResampling() async throws {
            let engine = AVAudioEngine()
            let hardware = AudioFormat(sampleRate: 44_100, channelCount: 1)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 441)
            let receiver = AppAudioReceiver()
            let frames = Mutex<[Float]>([])
            try receiver.rebuild(
                engine: engine,
                configuration: .init(outputHardwareFormat: hardware, transmitSoundIsolationEnabled: false),
                peers: ["peer"], rendersToHardware: true
            ) { frame in frames.withLock { $0 += frame.samples } }
            defer { receiver.stop() }
            for index in 0..<20 {
                let samples = (0..<480).map { Float(0.1 * sin(Double(index * 480 + $0) * 2 * .pi * 400 / 48_000)) }
                try receiver.play(
                    .init(
                        sequenceNumber: UInt64(index), format: .intercomMixer, capturedAt: Double(index) * 0.01,
                        samples: samples), peer: "peer")
            }
            let peer = try #require(receiver.snapshot.buses.first { $0.id == "rx-peer-peer" })
            #expect(
                peer.sources.first?.mixerFormat == hardware,
                "Decode normalizes once to the device clock; native output must not add another sample-rate converter")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
            var rendered: [Float] = []
            for _ in 0..<22 {
                #expect(try engine.renderOffline(441, to: buffer) == .success)
                rendered += Array(UnsafeBufferPointer(start: (try #require(buffer.floatChannelData))[0], count: 441))
                await Task.yield()
            }
            await AppTestSupport.waitUntil { frames.withLock { $0.count >= 8820 } }
            // Check gain before the OS main mixer's mono/stereo pan law, whose
            // channel mapping depends on the machine's current output device.
            #expect(
                abs(AudioLevelMeter.rmsLevel(samples: frames.withLock { Array($0[2205..<6615]) }) - 0.07071) < 0.001)
            #expect(rendered.contains { abs($0) > 0.04 })
        }

        @Test(arguments: [true, false]) func hardwareMeteringBatchesObserversWithoutDelayingPlayback(
            rendersToHardware: Bool
        ) async throws {
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 128)
            let receiver = AppAudioReceiver()
            let frames = Mutex<[PCMFrame]>([])
            try receiver.rebuild(
                engine: engine, configuration: .init(transmitSoundIsolationEnabled: false), peers: ["peer"],
                rendersToHardware: rendersToHardware
            ) { frame in frames.withLock { $0.append(frame) } }
            defer { receiver.stop() }
            try receiver.play(
                .init(
                    sequenceNumber: 0, format: .intercomMixer, capturedAt: 0,
                    samples: (0..<3840).map { Float(0.1 * sin(Double($0) * 2 * .pi * 400 / 48_000)) }), peer: "peer")
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
            var hardware: [Float] = []
            for _ in 0..<30 {
                #expect(try engine.renderOffline(128, to: buffer) == .success)
                hardware += Array(UnsafeBufferPointer(start: (try #require(buffer.floatChannelData))[0], count: 128))
                try await Task.sleep(for: .milliseconds(1))
            }
            await AppTestSupport.waitUntil { frames.withLock { $0.flatMap(\.samples).count >= 3840 } }
            let observed = frames.withLock { $0 }
            #expect(observed.flatMap(\.samples).count == 3840, "Metering must retain every rendered sample")
            #expect(
                observed.count == (rendersToHardware ? 4 : 30), "Only hardware observers may wait for a 20 ms batch")
            if rendersToHardware {
                #expect(
                    (hardware.firstIndex { abs($0) > 0.01 } ?? 3840) < 480,
                    "Hardware must play before the first 20 ms observer callback")
                #expect(zip(hardware, observed.flatMap(\.samples)).allSatisfy { abs($0 - $1) < 0.00001 })
            }
        }

        @Test(arguments: [256, 480]) func vadLookaheadKeepsPacketCadenceAcrossConversationPauses(frameCount: Int) {
            var controller = AudioTransmissionController()
            var delivered: [UInt64] = []
            for index in 0..<400 {
                let value: Float = (index / 50).isMultiple(of: 2) ? 0 : 0.2
                let output = controller.process(
                    frame: .init(
                        sequenceNumber: UInt64(index), format: .intercomMixer,
                        capturedAt: Double(index * frameCount) / 48000,
                        samples: Array(repeating: value, count: frameCount)), level: value)
                let frames = output.compactMap { packet -> PCMFrame? in
                    switch packet {
                    case .voice(let frame), .silence(let frame): return frame
                    }
                }
                if index >= 3 {
                    #expect(
                        frames.count == 1,
                        "VAD must not alternate between holding time and replaying a burst at speech boundaries")
                }
                delivered += frames.map(\.sequenceNumber)
            }
            #expect(
                delivered == Array(0..<UInt64(delivered.count)),
                "Every captured interval is delivered once in capture order")
        }

        @Test(arguments: [true, false]) func receiveMixerKeepsItsClockWhileChoosingLocalOrRemoteOutput(
            localPlayback: Bool
        ) async throws {
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
            let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
            pipeline.setHardwareOutputEnabled(localPlayback)
            var forwarded: [Float] = []
            pipeline.onOutputFrame = { forwarded += $0.samples }
            try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
            defer { pipeline.stop() }
            // No PCM callback or actor yield: the hardware render itself must play
            // the received samples, exactly once, through gain and the final limiter.
            let samples = (0..<9600).map { Float(0.1 * sin(Double($0) * 2 * .pi * 400 / 48000)) }
            _ = try pipeline.processReceivedAudioPacket(
                .init(
                    peerID: .init(rawValue: "peer"),
                    packet: .init(
                        sequenceNumber: 0, codec: .pcm16, format: .init(), capturedAt: 0, sampleCount: samples.count,
                        payload: PCM16Codec.encode(samples))))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            var rendered: [Float] = []
            for _ in 0..<22 {
                #expect(try engine.renderOffline(480, to: buffer) == .success)
                rendered += Array(UnsafeBufferPointer(start: (try #require(buffer.floatChannelData))[0], count: 480))
            }
            let steady = rendered[2400..<7200]
            let expectedRMS: Float = localPlayback ? 0.07071 : 0
            #expect(abs((steady.map { $0 * $0 }.reduce(0, +) / Float(steady.count)).squareRoot() - expectedRMS) < 0.001)
            await AppTestSupport.waitUntil { forwarded.contains { abs($0) > 0.01 } }
            #expect(
                forwarded.contains { abs($0) > 0.01 },
                "Muting the physical phone output must retain the processed PCM for the selected device")
            #expect((try #require(steady.map { abs($0) }.max())) < 0.101)
        }

        @Test func receivingSpeechChangesDuckingLevelWithoutChangingInputIOMode() {
            let harness = AppTestSupport.makeHarness()
            let viewModel = harness.viewModel
            let idle = viewModel.currentVoiceProcessingConfiguration()
            viewModel.setOtherAudioDuckingActive(true)
            let speaking = viewModel.currentVoiceProcessingConfiguration()
            viewModel.setOtherAudioDuckingActive(false)
            let quiet = viewModel.currentVoiceProcessingConfiguration()
            #expect(idle.voiceProcessingEnabled)
            #expect(speaking.voiceProcessingEnabled == idle.voiceProcessingEnabled)
            #expect(quiet.voiceProcessingEnabled == idle.voiceProcessingEnabled)
            #expect(idle.duckingLevel == .minimum)
            #expect(speaking.duckingLevel == .medium)
            #expect(quiet.duckingLevel == .minimum)
            viewModel.setDuckOthersEnabled(false)
            #expect(!viewModel.currentVoiceProcessingConfiguration().voiceProcessingEnabled)
        }

        @Test func nativeDuckingStaysCurrentWithoutOutputFrameDeliveryToApp() throws {
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
            let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
            let model = AppTestSupport.makeHarness(audioPipeline: pipeline).viewModel
            try pipeline.rebuild(configuration: .init(transmitSoundIsolationEnabled: false), peerIDs: ["peer"])
            defer { pipeline.stop() }
            model.isAudioReady = true
            var appFrames = 0
            pipeline.onOutputFrame = { _ in appFrames += 1 }
            #expect(!model.shouldApplyOtherAudioDucking(now: Date().timeIntervalSince1970))
            let frame = PCMFrame(sequenceNumber: 0, format: .intercomMixer, samples: Array(repeating: 0.2, count: 9600))
            _ = try pipeline.processReceivedAudioPacket(
                AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            for _ in 0..<22 { #expect(try engine.renderOffline(480, to: buffer) == .success) }

            // Native capture drains on its worker while MainActor still owns this test.
            let deadline = ContinuousClock.now + .milliseconds(300)
            while !model.shouldApplyOtherAudioDucking(now: Date().timeIntervalSince1970),
                ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.002)
            }
            #expect(appFrames == 0)
            #expect(model.shouldApplyOtherAudioDucking(now: Date().timeIntervalSince1970))
            #expect(!model.shouldApplyOtherAudioDucking(now: Date().timeIntervalSince1970 + 2))
            pipeline.stop()
            #expect(!model.shouldApplyOtherAudioDucking(now: Date().timeIntervalSince1970))
        }

    }
}
