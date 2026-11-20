import AuthenticationServices
import AVFAudio
import AudioCore
import Codec
import CryptoKit
import Foundation
import Synchronization
#if DEBUG
@testable import RTC
#else
import RTC
#endif
import SessionManager
import VADGate
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import RideIntercom

final class AudioE2ETests: XCTestCase {
    @MainActor
    private func observedOutputBatches(_ model: IntercomViewModel) -> Int {
        model.nativeRenderedOutputBatchCount + model.scheduledOutputBatchCount
    }

    func testFixturePreservesClockGapsWithoutDelayingLaterSpeech() {
        var fixture = CaptureTimedFixture(samples: (0..<48000).map(Float.init))
        XCTAssertEqual(fixture.render(capturedAt: 100, format: .init(), frameCount: 480), (0..<480).map(Float.init))
        XCTAssertEqual(fixture.render(capturedAt: 100.02, format: .init(), frameCount: 480), (960..<1440).map(Float.init),
            "A missing 10 ms interval must omit exactly those samples, not shift the rest of the utterance")
        XCTAssertEqual(fixture.render(capturedAt: 100.03, format: .init(), frameCount: 480), (1440..<1920).map(Float.init))
    }
    #if os(macOS)
    @MainActor
    func testMacFixturePacesCompletedSamples() async throws {
        let input = SpeechFileInput(samples: Array(repeating: 0.1, count: 48000))
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init())) { _ in }
        defer { try? input.stopCapture() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(input.firstCaptureTime)
        XCTAssertGreaterThanOrEqual(input.captureTiming["minimumCompletedSampleAge"] ?? -1, -0.001,
            "The fixture must finish capturing every sample before delivering it, just like a microphone")
    }
    #endif
    /// Same production mixer/codec/output, in one process, without RTC or VAD.
    /// Compare 20 ms file delivery with the 100 ms capture batches seen on iOS.
    @MainActor
    func testSpeechContinuityWithoutNetwork() async throws {
        let samples = try SpeechFileInput(name: "speech-ja").samples
        var failures: [String] = []
        for milliseconds in [20, 100] {
            let name = "pipeline-\(milliseconds)ms"
            let probe = RenderedAudioProbe()
            let engine = AVAudioEngine()
            let output = SystemAudioOutputStreamBackend(engine: engine)
            try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in probe.append(buffer, time: time) }
            defer { engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
            let hardware = try output.startRendering(configuration: .intercom)
            let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
            defer { pipeline.stop() }
            let processingFailureStore = Mutex<[String]>([])
            pipeline.onTransmitPacket = { [weak pipeline] packet in
                guard let pipeline else { return }
                do { try pipeline.processReceivedAudioPacket(.init(peerID: PeerID(rawValue: "loopback"), packet: packet)) }
                catch { processingFailureStore.withLock { $0.append(String(describing: error)) } }
            }
            try pipeline.rebuild(configuration: .init(rtcSendFormat: .init(sampleRate: 48_000, channelCount: 1),
                outputHardwareFormat: hardware, preferredCodec: .pcm16, transmitSoundIsolationEnabled: false,
                maximumBufferedDuration: 0.1,
                receiveMaximumBufferedDuration: AppAudioPipelineConfiguration.callReceiveMaximumBufferedDuration,
                receivePlayoutDelay: AppAudioPipelineConfiguration.callReceivePlayoutDelay), peerIDs: ["loopback"])
            let start = ContinuousClock.now
            let count = milliseconds * 48
            let captureDuration = Double(count) / 48_000
            let firstCapturedAt = ProcessInfo.processInfo.systemUptime - captureDuration
            var resetStart = 0
            for index in 0..<(22_000 / milliseconds) {
                try await Task.sleep(until: start + .milliseconds(index * milliseconds), clock: .continuous)
                if index == 2_000 / milliseconds { probe.reset(); resetStart = output.playbackResetCount ?? 0 }
                let block = (0..<count).map { samples[(index * count + $0) % samples.count] }
                try pipeline.processCapturedFrame(PCMFrame(sequenceNumber: UInt64(index),
                    format: .init(sampleRate: 48_000, channelCount: 1),
                    capturedAt: firstCapturedAt + Double(index) * captureDuration, samples: block))
            }
            try await Task.sleep(until: start + .seconds(22), clock: .continuous)
            let rendered = probe.snapshot()
            let processingFailures = processingFailureStore.withLock { $0 }
            let resets = (output.playbackResetCount ?? 0) - resetStart
            let playout = pipeline.receivePlayoutDiagnostics(peerID: "loopback")
            XCTAssertNotNil(playout)
            let mixer = String(describing: pipeline.snapshot)
            pipeline.stop()
            try output.stopRendering()
            let continuity = await Task.detached {
                SpeechContinuity.measure(reference: samples, referenceRate: 48_000,
                                         output: rendered.samples, outputRate: rendered.rate)
            }.value
            let measurement: [String: Any] = ["scenario": name, "role": "pipeline", "transport": "none",
                "remoteFixture": "speech-ja", "continuityPassed": continuity.passed && continuity.missingActiveRatio == 0,
                "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
                "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
                "outputPlaybackResets": resets, "playoutAdjustments": playout?.adjustments ?? 0,
                "playoutResets": playout?.resets ?? 0, "mixer": mixer, "processingFailures": processingFailures]
            let data = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]),
                                     uniformTypeIdentifier: "public.json")
            data.name = name + "-measurement"; data.lifetime = .keepAlways; add(data)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
            defer { try? FileManager.default.removeItem(at: url) }
            try probe.writeWAV(to: url, rendered: rendered)
            let recording = XCTAttachment(contentsOfFile: url)
            recording.name = name + "-speech"; recording.lifetime = .keepAlways; add(recording)
            if !continuity.passed || continuity.missingActiveRatio != 0 || !processingFailures.isEmpty || rendered.invalid > 0
                || rendered.samples.count < Int(rendered.rate * 19) {
                failures.append("\(name): matched=\(continuity.matchedWindowRatio), missing=\(continuity.missingActiveRatio), resets=\(resets), errors=\(processingFailures)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    func testContinuityRejectsGapsRepeatsAndMissingSpeech() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let clean = (0..<960_000).map { speech[($0 + 12_345) % speech.count] * 0.3 }
        func measure(_ output: [Float]) -> SpeechContinuity {
            SpeechContinuity.measure(reference: speech, referenceRate: 48_000, output: output, outputRate: 48_000)
        }
        let cleanResult = measure(clean)
        XCTAssertTrue(cleanResult.passed, "Fixed delay and gain must preserve speech")
        XCTAssertTrue(cleanResult.missingIntervals.isEmpty)
        let resampled = (0..<Int(Double(clean.count - 1) * 44_100 / 48_000)).map { index -> Float in
            let position = Double(index) * 48_000 / 44_100
            let lower = Int(position), fraction = Float(position - Double(lower))
            return clean[lower] * (1 - fraction) + clean[lower + 1] * fraction
        }
        let fractionalRate = SpeechContinuity.measure(reference: speech, referenceRate: 48_000,
            output: resampled, outputRate: 44_100)
        XCTAssertTrue(fractionalRate.passed)
        XCTAssertEqual(fractionalRate.missingActiveRatio, 0)
        XCTAssertEqual(fractionalRate.referenceOffsetSeconds, 12_345.0 / 48_000, accuracy: 0.002,
            "44.1 samples per millisecond must not accumulate a truncated-bin clock error")
        let filtered = clean.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }.map { tanh($0 * 8) }
        XCTAssertTrue(measure(filtered).passed, "Coloration alone is not a dropout")
        var gaps = clean
        for index in gaps.indices where index % 24_000 < 4_800 { gaps[index] = 0 }
        let gapResult = measure(gaps)
        XCTAssertFalse(gapResult.passed, "Repeated 100 ms losses must fail")
        XCTAssertGreaterThan(gapResult.missingActiveRatio, 0.05)
        let durations = gapResult.missingIntervals.map { $0.endSeconds - $0.startSeconds }
        XCTAssertEqual(durations.reduce(0, +), gapResult.activeSeconds * gapResult.missingActiveRatio, accuracy: 0.001)
        XCTAssertEqual(durations.max() ?? 0, gapResult.longestMissingSeconds, accuracy: 0.001)
        var missing = clean
        missing.replaceSubrange(240_000..<264_000, with: repeatElement(0, count: 24_000))
        let missingResult = measure(missing)
        XCTAssertFalse(missingResult.passed, "One missing half-second must fail")
        XCTAssertFalse(missingResult.missingIntervals.isEmpty)
        XCTAssertTrue(missingResult.missingIntervals.allSatisfy { $0.startSeconds >= 5 && $0.endSeconds <= 5.5 })
        var repeated = clean
        repeated.replaceSubrange(240_000..<288_000, with: clean[192_000..<240_000])
        XCTAssertFalse(measure(repeated).passed, "Repeated speech must fail even without silence")
        var reordered = clean
        reordered.replaceSubrange(240_000..<480_000, with: clean[480_000..<720_000])
        reordered.replaceSubrange(480_000..<720_000, with: clean[240_000..<480_000])
        XCTAssertFalse(measure(reordered).passed, "Out-of-order speech must fail")
        XCTAssertFalse(measure(Array(repeating: 0, count: clean.count)).passed)
        XCTAssertFalse(measure((0..<clean.count).map { other[$0 % other.count] }).passed)
    }

    func testSpeechMatcherRejectsSilenceAndWrongSpeaker() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let delayed = Array(repeating: Float(0), count: 12_345) + speech.map { $0 * 0.2 }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: delayed, outputRate: 48_000), 0.95)
        XCTAssertEqual(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: Array(repeating: 0, count: speech.count), outputRate: 48_000), 0)
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: other, outputRate: 48_000), 0.4)
        let filtered = speech.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: filtered.map { tanh($0 * 8) }, outputRate: 48_000), 0.8)
        var state: UInt64 = 1
        let noise = speech.map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(state >> 32) / Float(UInt32.max) - 0.5
        }
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: noise, outputRate: 48_000), 0.4)
    }

    @MainActor
    func testSystemSessionAcceptsCallProfiles() throws {
        let manager = AudioSessionManager()
        for configuration in [
            AudioSessionConfiguration(),
            AudioSessionConfiguration(prefersEchoCancelledInput: true),
            AudioSessionConfiguration(defaultToSpeaker: true),
            AudioSessionConfiguration(mode: .voiceChat),
        ] {
            let report = try manager.configure(configuration)
            print("SYSTEM SESSION: \(report)")
            for operation in report.operations {
                if case .failed = operation.result { XCTFail("\(configuration): \(operation)") }
            }
        }
    }

    @MainActor
    func testDuplexSpeechOverNetwork() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        let scenarioData = try XCTUnwrap(env["AUDIO_E2E_SCENARIOS"]?.data(using: .utf8))
        let scenarios = try JSONDecoder().decode([AudioE2EScenario].self, from: scenarioData)
        let initial = try XCTUnwrap(scenarios.first)
        let run = try XCTUnwrap(env["AUDIO_E2E_RUN"], "Run scripts/audio_e2e.py; a second endpoint is required")
        let role = try XCTUnwrap(env["AUDIO_E2E_ROLE"])
        XCTAssertTrue(["a", "b"].contains(role))
        let groupID = try XCTUnwrap(UUID(uuidString: run))
        let transport = env["AUDIO_E2E_TRANSPORT"] ?? "local"
        let standaloneReceiver = env["AUDIO_E2E_STANDALONE_RECEIVER"] == "1"
        let mixed = transport == "mixed"
        let usesInternet = transport == "webrtc" || mixed
        let startsBeforeInternet = env["AUDIO_E2E_DELAY_INTERNET"] == "1"
        let waitsForLateParticipant = env["AUDIO_E2E_WAIT_FOR_LATE_PARTICIPANT"] == "1"
        let movesToBackground = env["AUDIO_E2E_BACKGROUND_AFTER_START"] == "1"
        let checksInternetRecovery = env["AUDIO_E2E_BACKGROUND_INTERNET_RECOVERY"] == "1"
        let checksLocalRecovery = env["AUDIO_E2E_BACKGROUND_LOCAL_RECOVERY"] == "1"
        let checksBackgroundSilence = env["AUDIO_E2E_BACKGROUND_SILENCE"] == "1"
        let checksBackgroundMute = env["AUDIO_E2E_BACKGROUND_MIC_OFF"] == "1"
        let recovery = checksInternetRecovery || checksLocalRecovery
        let mutedWait = env["AUDIO_E2E_BACKGROUND_MUTED_WAIT_SECONDS"].map { Int($0) ?? -1 } ?? 0
        XCTAssertTrue((0...300).contains(mutedWait))
        if standaloneReceiver {
            XCTAssertTrue(role == "b" && transport == "local" && !waitsForLateParticipant && !movesToBackground
                && !recovery && !checksBackgroundMute && !checksBackgroundSilence && mutedWait == 0)
            XCTAssertEqual(scenarios.count, 1)
        }
        if mutedWait > 0 { XCTAssertTrue(checksBackgroundMute && recovery) }
        if waitsForLateParticipant { XCTAssertTrue(["local", "webrtc"].contains(transport)) }
        if startsBeforeInternet { XCTAssertTrue(mixed) }
        if movesToBackground { XCTAssertTrue(waitsForLateParticipant) }
        if checksInternetRecovery { XCTAssertTrue(movesToBackground && waitsForLateParticipant && transport == "webrtc") }
        if checksLocalRecovery { XCTAssertTrue(movesToBackground && waitsForLateParticipant && transport == "local") }
        if checksBackgroundSilence || checksBackgroundMute {
            XCTAssertTrue(movesToBackground && waitsForLateParticipant)
            if recovery { XCTAssertTrue(checksBackgroundMute && mutedWait > 0) }
            XCTAssertFalse(checksBackgroundSilence && checksBackgroundMute)
        }
        let soleRoute: RouteKind = usesInternet ? .webRTC : .multipeer
        let groupSecret = "fixture-only-\(run)"
        let room = RTCCredential.derived(groupID: groupID.uuidString, secret: groupSecret).groupHash
        #if DEBUG
        let instrumentedRoutes = mixed || checksLocalRecovery ? MixedRouteAudioE2E() : nil
        #else
        if mixed || checksLocalRecovery { throw NSError(domain: "Local route fault injection requires Debug-Validation", code: 1) }
        #endif
        let workerURL: URL?
        var worker: AudioE2EWorker?
        if usesInternet || waitsForLateParticipant {
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(env["AUDIO_E2E_WORKER_URL"])))
            workerURL = url
            if role == "a" {
                let fixture = try AudioE2EWorker(port: UInt16(try XCTUnwrap(url.port)), run: run, room: room,
                                                 checksInternetRecovery: checksInternetRecovery,
                                                 holdsInternetSignaling: startsBeforeInternet)
                worker = fixture
                try await fixture.start()
                addTeardownBlock { await fixture.stop() }
            }
        } else { workerURL = nil }
        let internet = usesInternet ? workerURL.map {
            CloudflareRealtimeConfiguration(workerURL: $0, accessToken: run)
        } : nil
        let suffix = env["AUDIO_E2E_SPEECH_PAIR"] == "japanese" ? "-ja" : ""
        let fixtures = env["AUDIO_E2E_SPEECH_PAIR"] == "conversation"
            ? ["conversation-ja", "conversation-reply-ja"] : ["speech" + suffix, "reply" + suffix]
        let localFixture = fixtures[role == "a" ? 0 : 1]
        let remoteFixture = fixtures[role == "a" ? 1 : 0]
        let outputEngine = AVAudioEngine()
        let input = try SpeechFileInput(name: localFixture, engine: outputEngine)
        if mixed { input.setFrameDeliveryEnabled(false) }
        let remote = try SpeechFileInput(name: remoteFixture)
        let probe = RenderedAudioProbe()
        let mixedProbe = RenderedAudioProbe(), decodedProbe = RenderedAudioProbe()
        let output = SystemAudioOutputStreamBackend(engine: outputEngine)
        try outputEngine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in probe.append(buffer, time: time) }
        defer { outputEngine.mainMixerNode.removeTap(onBus: 0) }
        let namespace = "RideIntercom.AudioE2E.\(run).\(role)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let keychain = FixtureKeychain()
        let credentials = KeychainGroupCredentialStore(keychain: keychain, namespace: namespace)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        defer {
            defaults.removePersistentDomain(forName: namespace)
            for ref in (try? credentials.references()) ?? [] { try? credentials.delete(reference: ref) }
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = UserDefaultsAppSettingsStore(defaults: defaults)
        let enabledRoutes: Set<RouteKind> = mixed ? [.multipeer, .webRTC] : transport == "webrtc" ? [.webRTC] : [.multipeer]
        var configuration = AppSettings(enabledRTCTransportRoutes: enabledRoutes)
        configuration.preferredTransmitCodec = AudioCodecIdentifier(rawValue: initial.codec)
        configuration.rtcAudioFormatPreset = try XCTUnwrap(RTCAudioFormatPreset(rawValue: initial.format))
        configuration.audioSessionProfile = try XCTUnwrap(AudioSessionProfile(rawValue: initial.profile))
        settings.save(configuration)
        let callSession: RideIntercomCallSessionAdapter?
        if usesInternet || checksLocalRecovery {
            callSession = RideIntercomCallSessionAdapter(memberID: "e2e-\(role)-\(run.prefix(8))", internetConfiguration: internet,
                sessionFactory: { policy, routes, configuration in
                    #if DEBUG
                    if let instrumentedRoutes {
                        return instrumentedRoutes.makeSession(routes: routes, internet: configuration)
                    }
                    #endif
                    return RTC.CallSessionFactory.makeSession(.init(
                        routeConfiguration: .init(enabledRoutes: routes, preferredRoute: .webRTC), audioPolicy: policy,
                        webRTC: .init(cloudflareConfigurationProvider: { _ in configuration },
                                      engineFactory: { makeAudioE2EWebRTCEngine() })))
                })
        } else { callSession = nil }
        let account = AppleAccountSession(keychain: FixtureKeychain(), defaults: defaults, namespace: namespace, credentialState: { _ in .authorized })
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        XCTAssertTrue(account.completeSignIn(userID: "audio-e2e-" + role, state: request.state))
        let viewModel = IntercomViewModel(
            accountSession: account,
            callSession: callSession,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials),
            appSettingsStore: settings,
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: namespace),
            localMemberIdentityStore: UserDefaultsLocalMemberIdentityStore(defaults: defaults,
                makeID: { "e2e-\(role)-\(run.prefix(8))" }, defaultDisplayName: { "Audio E2E \(role)" }),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: namespace),
            requestMicrophoneAccess: {
                #if os(iOS)
                await AVAudioApplication.requestRecordPermission()
                #else
                // The Mac endpoint supplies file samples without opening a microphone.
                true
                #endif
            },
            audioInputCapture: AudioInputStreamCapture(configuration: .intercom(voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()), backend: input),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: output)
        )
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(initial.transmitIsolation)
        // The Mac and Simulator share one host audio service. The runner starts
        // the other endpoint after this native setup, before either media test.
        FileHandle.standardOutput.write(Data("AUDIO_E2E_NATIVE_READY\n".utf8))
        let token = try GroupInviteToken.make(
            authority: DirectInvitationAuthority(keychain: keychain, namespace: namespace + ".Inviter"),
            signer: DeviceIdentitySigner(memberID: "fixture-owner", key: P256.Signing.PrivateKey()), groupID: groupID, groupName: "Audio E2E",
            groupSecret: groupSecret, inviterMemberID: "fixture-owner")
        let invitation = try GroupInviteTokenCodec.joinURL(for: token)
        if standaloneReceiver {
            try await sendToStandaloneReceiver(viewModel: viewModel, invitation: invitation,
                                               directory: directory, seconds: initial.seconds)
            return
        }
        if waitsForLateParticipant, role == "b" {
            try await waitForFirstParticipant(at: XCTUnwrap(workerURL), room: room, token: run, timeout: 45 + mutedWait)
        }
        let joiningStarted = ContinuousClock.now
        try viewModel.acceptInviteURL(invitation)
        let waitingCall = viewModel.currentCallReference
        let waitingDeadline = viewModel.callDisconnectDeadline
        if mutedWait > 0, role == "a" { XCTAssertTrue(viewModel.setCallMuted(true, for: waitingCall)) }
        if movesToBackground {
            try await leaveForSettingsAfterStartingCall(viewModel: viewModel, joiningStarted: joiningStarted)
        }
        let rendezvous: (@MainActor (String, Double) async throws -> Void)?
        if mutedWait > 0 {
            let worker = try XCTUnwrap(workerURL)
            rendezvous = { phase, timeout in
                try await AudioE2EWorker.waitForPairStage(at: worker, room: room, run: run, role: role, phase: phase, timeout: timeout)
            }
        } else {
            rendezvous = nil
        }
        let barrier = AudioE2EBarrier(session: viewModel.callSession, rendezvous: rendezvous)

        func status() -> String {
            "state=\(viewModel.connectionState) authenticated=\(viewModel.authenticatedPeerIDs.count) ready=\(viewModel.isAudioReady) tx=\(viewModel.sentVoicePacketCount) rx=\(viewModel.receivedVoicePacketCount) outputBatches=\(observedOutputBatches(viewModel)) audioError=\(viewModel.audioErrorMessage ?? "none") input=\(String(describing: viewModel.lastInputStreamOperationReport?.result)) output=\(String(describing: viewModel.lastOutputStreamOperationReport?.result)) session=\(String(describing: viewModel.lastAudioSessionConfigurationReport?.operations))"
        }
        defer {
            let attachment = XCTAttachment(string: status() + "\nmixer=\(viewModel.audioPipeline.snapshot)\nvad=\(viewModel.vadGateRuntimeSnapshot)")
            attachment.name = "endpoint-\(role)-status"; attachment.lifetime = .keepAlways; add(attachment)
        }
        if waitsForLateParticipant, role == "a" {
            try await waitUntil(seconds: 30, description: "The first endpoint has the route and native audio ready", status: status) {
                let routeReady = usesInternet ? viewModel.availableCallRoutes == [.webRTC]
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
                    XCTAssertEqual(viewModel.currentCallReference, waitingCall)
                    XCTAssertEqual(viewModel.callDisconnectDeadline, waitingDeadline)
                }
                checkBackgroundIfRequested(movesToBackground)
                try await Task.sleep(for: mutedWait > 0 ? .seconds(1) : .milliseconds(100))
            } while waitingSince.duration(to: .now) < .seconds(max(3, mutedWait))
            print("Audio E2E: First endpoint waited on \(transport) alone with native audio active for \(waitingSince.duration(to: .now)); muted=\(viewModel.effectiveInputMuted)")
            let service = try XCTUnwrap(worker)
            await service.markWaitingParticipantReady()
        }
        try await waitUntil(seconds: 60, description: "Verified peer, RTC audio admission and active audio", status: status) {
            viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
                && IntercomViewModel.admittedMemberships(in: viewModel.peerProfiles).count == 1
        }
        let peerID = try XCTUnwrap(viewModel.authenticatedPeerIDs.first)
        if waitsForLateParticipant {
            XCTAssertEqual(viewModel.availableCallRoutes, [soleRoute])
            XCTAssertEqual(viewModel.activeGroupID, groupID)
            print("Audio E2E: Authenticated remote over \(transport) after \(joiningStarted.duration(to: .now))")
            try await verifyPairedAudio(viewModel: viewModel, barrier: barrier, probe: probe,
                scenario: usesInternet ? "late-internet" : "late-local", route: soleRoute,
                transport: transport, role: role, local: input.samples, remote: remote.samples,
                directory: directory, seconds: initial.seconds, movesToBackground: movesToBackground,
                expectsRemoteSpeech: mutedWait == 0 || role == "a")
            if checksBackgroundSilence || checksBackgroundMute {
                let scenario = checksBackgroundMute ? "background-mic-off" : "background-silence"
                try await verifyBackgroundQuietPeriod(viewModel: viewModel, barrier: barrier, input: input, probe: probe,
                    route: soleRoute, peerID: peerID, groupID: groupID, role: role, transport: transport,
                    scenario: scenario, bothMute: checksBackgroundMute, keepMuted: recovery)
                if !recovery {
                    try await verifyPairedAudio(viewModel: viewModel, barrier: barrier, probe: probe,
                        scenario: "\(scenario)-resumed", route: soleRoute, transport: transport,
                        role: role, local: input.samples, remote: remote.samples,
                        directory: directory, seconds: initial.seconds, movesToBackground: true,
                        expectsRemoteSpeech: !checksBackgroundMute || role == "a")
                    if checksBackgroundMute { XCTAssertEqual(viewModel.effectiveInputMuted, role == "a") }
                }
            }
            if checksInternetRecovery {
                try await verifyBackgroundInternetRecovery(viewModel: viewModel, workerURL: XCTUnwrap(workerURL),
                    room: room, token: run, groupID: groupID, peerID: peerID,
                    participantID: "e2e-\(role)-\(run.prefix(8))")
            }
            #if DEBUG
            if checksLocalRecovery {
                try await verifyBackgroundLocalRecovery(viewModel: viewModel, routes: XCTUnwrap(instrumentedRoutes),
                    barrier: barrier, groupID: groupID, peerID: peerID, expectsMediaDuringRecovery: !checksBackgroundMute)
            }
            #endif
            if recovery {
                if checksBackgroundMute {
                    XCTAssertTrue(viewModel.effectiveInputMuted)
                    if role == "b" { XCTAssertTrue(viewModel.setCallMuted(false, for: waitingCall)) }
                }
                try await verifyPairedAudio(viewModel: viewModel, barrier: barrier, probe: probe,
                    scenario: checksInternetRecovery ? "background-internet-recovered" : "background-local-recovered",
                    route: soleRoute, transport: transport, role: role, local: input.samples, remote: remote.samples,
                    directory: directory, seconds: initial.seconds, movesToBackground: true,
                    expectsRemoteSpeech: !checksBackgroundMute || role == "a")
            }
            if mutedWait > 0 {
                XCTAssertEqual(viewModel.currentCallReference, waitingCall)
                XCTAssertEqual(viewModel.callDisconnectDeadline, waitingDeadline)
                XCTAssertEqual(viewModel.effectiveInputMuted, role == "a")
            }
            return
        }
        #if DEBUG
        if let instrumentedRoutes {
            try await instrumentedRoutes.verify(test: self, viewModel: viewModel, peer: PeerID(rawValue: peerID),
                role: role, worker: worker, barrier: barrier, probe: probe, input: input, remote: remote.samples,
                directory: directory, seconds: initial.seconds, startsBeforeInternet: startsBeforeInternet)
            return
        }
        #endif
        let receivedTiming = Mutex<[[String: Double]]>([])
        let decodeFailures = Mutex(0)
        @Sendable func timing(_ packet: RTCAudioPacket) -> [String: Double] {
            ["sequence": Double(packet.sequenceNumber), "capture": packet.capturedAt,
             "host": ProcessInfo.processInfo.systemUptime,
             "duration": Double(packet.sampleCount ?? 0) / Double(packet.format.channelCount) / packet.format.sampleRate]
        }
        // Observe the PCM returned by the shipping receive path. Starting an
        // additional decoder in the middle of a stream has different priming
        // history, adds CPU load and cannot measure the real decode boundary.
        viewModel.callSession.processReceivedAudio = { [pipeline = viewModel.audioPipeline] received in
            var entry = timing(received.packet)
            do {
                let frame = try pipeline.processReceivedAudioPacket(received)
                entry["handled"] = ProcessInfo.processInfo.systemUptime
                if let playout = pipeline.receivePlayoutDiagnostics(peerID: received.peerID.rawValue) {
                    entry["buffered"] = playout.bufferedDuration
                    entry["adjustments"] = Double(playout.adjustments)
                    entry["resets"] = Double(playout.resets)
                }
                receivedTiming.withLock { $0.append(entry) }
                decodedProbe.append(frame, preservingTimeline: true)
                return .processed(level: (try? AudioSignalMeter.measure(frame).rms) ?? 0)
            } catch AppAudioPipelineError.notConfigured {
                return .unavailable
            } catch {
                decodeFailures.withLock { $0 += 1 }
                return .failed(String(describing: type(of: error)))
            }
        }
        // Preserve every failing quality condition and its recording. Connection
        // setup still throws on timeout, so a missing peer cannot count as a run.
        continueAfterFailure = true
        var continuityFailures: [String] = []
        for scenario in scenarios {
            try await barrier.meet("begin-" + scenario.id)
            try scenario.apply(to: viewModel, peerID: peerID)
            try await waitUntil(seconds: 60, description: "Reconfigured audio " + scenario.id, status: status) {
                viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
            }
            try await barrier.meet("configured-" + scenario.id)
            // Drain bounded playback and effect tails before measuring a mute.
            try await Task.sleep(for: .seconds(2))
            scenario.verifyApplied(to: viewModel, peerID: peerID)
            probe.reset()
            let originalTransmit = viewModel.audioPipeline.onTransmitPacket
            let originalOutput = viewModel.audioPipeline.onOutputFrame
            mixedProbe.reset(); decodedProbe.reset()
            receivedTiming.withLock { $0.removeAll(keepingCapacity: true) }
            let failuresBefore = decodeFailures.withLock { $0 }
            var outputTiming: [[String: Double]] = []
            viewModel.audioPipeline.onOutputFrame = { frame in
                mixedProbe.append(frame)
                outputTiming.append(["capture": frame.capturedAt, "host": ProcessInfo.processInfo.systemUptime,
                    "duration": Double(frame.frameCount) / frame.format.sampleRate,
                    "queued": output.bufferedOutputDuration ?? 0])
                originalOutput?(frame)
            }
            let transmittedTiming = Mutex<[[String: Double]]>([])
            viewModel.audioPipeline.onTransmitPacket = { packet in
                transmittedTiming.withLock { $0.append(timing(packet)) }; originalTransmit?(packet)
            }
            func dropCounts() -> [String: Int] {
                ["capture": input.droppedCaptureFrameCount,
                 "delivery": viewModel.inputFrameDelivery?.droppedFrameCount ?? 0,
                 "render": viewModel.audioPipeline.droppedRenderFrameCount,
                 "sender": (viewModel.callSession as? RideIntercomCallSessionAdapter)?.droppedAudioPacketCount ?? 0]
            }
            let dropsBefore = dropCounts()
            let before = (viewModel.sentVoicePacketCount, viewModel.receivedVoicePacketCount,
                          observedOutputBatches(viewModel), output.playbackResetCount ?? 0)
            let start = ContinuousClock.now
            while start.duration(to: .now) < .seconds(scenario.seconds) {
                XCTAssertTrue(viewModel.isAudioReady, "\(scenario.id): \(status())")
                XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1, status())
                XCTAssertNil(viewModel.audioErrorMessage, status())
                try await Task.sleep(for: .milliseconds(100))
            }
            if transport == "local", !scenario.expectsSilence {
                let statistics = viewModel.networkDiagnostics?.routes.first { $0.route == .multipeer }?.statistics
                XCTAssertGreaterThan(statistics?.sentMediaDatagrams ?? 0, 0, "Local audio must use the UDP media path")
                XCTAssertGreaterThan(statistics?.receivedMediaDatagrams ?? 0, 0, "Local audio must arrive over UDP")
            }
            let rendered = probe.snapshot()
            let firstCapture = input.firstCaptureTime
            let firstOutput = probe.firstOutputTime
            viewModel.audioPipeline.onTransmitPacket = originalTransmit
            viewModel.audioPipeline.onOutputFrame = originalOutput
            let drops = dropCounts().map { ($0.key, $0.value - (dropsBefore[$0.key] ?? 0)) }
            let dropped = Dictionary(uniqueKeysWithValues: drops)
            let scenarioID = scenario.id, sentTrace = transmittedTiming.withLock { $0 }, receivedTrace = receivedTiming.withLock { $0 }, renderedTrace = outputTiming
            let traceData = try await Task.detached {
                try JSONSerialization.data(withJSONObject: ["traceForScenario": scenarioID,
                    "transmitted": sentTrace, "received": receivedTrace, "output": renderedTrace])
            }.value
            let trace = XCTAttachment(data: traceData, uniformTypeIdentifier: "public.json")
            trace.name = "endpoint-\(role)-\(scenario.id)-packet-timing"; trace.lifetime = .keepAlways; add(trace)
            let tx = viewModel.sentVoicePacketCount - before.0
            let rx = viewModel.receivedVoicePacketCount - before.1
            let outputBatches = observedOutputBatches(viewModel) - before.2
            let playbackResets = (output.playbackResetCount ?? 0) - before.3
            XCTAssertEqual(rendered.invalid, 0)
            XCTAssertGreaterThan(rendered.samples.count, Int(rendered.rate * scenario.seconds * 0.8))
            let remoteSamples = remote.samples, localSamples = input.samples
            let mixedRecording = mixedProbe.snapshot()
            let decodedRecording = decodedProbe.snapshot()
            // Analysis must not block the app actor and manufacture a keepalive timeout.
            let (match, localMatch, continuity) = await Task.detached {
                (RenderedAudioProbe.speechMatch(reference: remoteSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate),
                 RenderedAudioProbe.speechMatch(reference: localSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate),
                 SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                    output: rendered.samples, outputRate: rendered.rate))
            }.value
            let mixedContinuity = await Task.detached {
                SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                    output: mixedRecording.samples, outputRate: mixedRecording.rate)
            }.value
            let decodedContinuity = await Task.detached {
                SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                    output: decodedRecording.samples, outputRate: decodedRecording.rate)
            }.value
            XCTAssertEqual(decodeFailures.withLock { $0 } - failuresBefore, 0)
            let peak = rendered.samples.reduce(Float(0)) { max($0, abs($1)) }
            let needsReplies = remoteFixture.hasPrefix("conversation") && !scenario.expectsSilence
            let replies = try await Task.detached {
                needsReplies ? try ConversationIdentity.measure(fixture: remoteFixture, reference: remoteSamples,
                    output: rendered.samples, outputRate: rendered.rate, referenceOffset: continuity.referenceOffsetSeconds)
                : nil
            }.value
            if let replies, !replies.passed { continuityFailures.append("\(scenario.id): short reply identity failed: \(replies)") }
            XCTAssertLessThanOrEqual(peak, 1.001, "Limiter must bound the actual output")
            let report = viewModel.audioPipeline.codecRuntimeReport
            let continuityPassed = continuity.passed && continuity.missingActiveRatio == 0 && (replies?.passed ?? true)
            let measurement: [String: Any] = ["scenario": scenario.id, "role": role, "transport": transport,
                "localFixture": localFixture, "remoteFixture": remoteFixture,
                "localFixtureDurationSeconds": Double(input.samples.count) / 48_000,
                "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
                "continuityPassed": continuityPassed,
                "acknowledgements": try replies.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull(),
                "outputPlaybackResets": playbackResets,
                "firstCaptureHostTime": firstCapture as Any? ?? NSNull(),
                "firstOutputHostTime": firstOutput as Any? ?? NSNull(),
                "firstMixedHostTime": mixedProbe.firstOutputTime as Any? ?? NSNull(),
                "mixedContinuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(mixedContinuity)),
                "firstDecodedCaptureTime": decodedProbe.firstOutputTime as Any? ?? NSNull(),
                "decodedContinuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(decodedContinuity)),
                "outputPresentationLatencySeconds": outputEngine.outputNode.outputPresentationLatency,
                "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
                "voiceProcessingTimings": input.voiceProcessingTimings,
                "networkDiagnostics": try viewModel.networkDiagnostics.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull(),
                "droppedFramesAndPackets": dropped,
                "requestedCodec": scenario.codec, "selectedCodec": report.selectedCodec.rawValue,
                "fallback": report.isFallback, "format": scenario.format, "requestedBitRate": scenario.bitRate,
                "selectedBitRate": report.activeConfiguration.activeBitRate as Any? ?? NSNull(),
                "sessionReport": String(describing: viewModel.lastAudioSessionConfigurationReport),
                "voiceProcessingReport": String(describing: viewModel.lastVoiceProcessingOperationReport),
                "mixer": String(describing: viewModel.audioPipeline.snapshot),
                "remoteSpeechCorrelation": match, "localSpeechCorrelation": localMatch,
                "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
                "peak": peak, "transmitted": tx, "received": rx, "outputBatches": outputBatches,
                "expectedSilence": scenario.expectsSilence]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]),
                uniformTypeIdentifier: "public.json")
            attachment.name = "endpoint-\(role)-\(scenario.id)-measurement"; attachment.lifetime = .keepAlways; add(attachment)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var recordings = [("speech", rendered)]
            if !scenario.expectsSilence && !continuityPassed {
                recordings.append(("decoded", decodedRecording))
                recordings.append(("mixed", mixedRecording))
            }
            for (stage, snapshot) in recordings where !snapshot.samples.isEmpty {
                let name = "endpoint-\(role)-\(scenario.id)-\(stage)"
                let url = directory.appendingPathComponent("\(name).wav")
                try await Task.detached { try probe.writeWAV(to: url, rendered: snapshot) }.value
                let recording = XCTAttachment(contentsOfFile: url)
                recording.name = name; recording.lifetime = .keepAlways; add(recording)
            }
            if scenario.expectsSilence {
                XCTAssertLessThan(peak, 0.001, "\(scenario.id) must silence the actual render output")
            } else {
                XCTAssertTrue(dropped.values.allSatisfy { $0 == 0 }, "\(scenario.id): internal drops \(dropped)")
                XCTAssertGreaterThan(tx, 20, status())
                XCTAssertGreaterThan(rx, 20, status())
                XCTAssertGreaterThan(outputBatches, 20, status())
                XCTAssertGreaterThan(match, 0.45, "Remote speech missing in \(scenario.id): \(status())")
                XCTAssertGreaterThan(match, localMatch + 0.10, "Reject local echo and unrelated audio")
                XCTAssertEqual(continuity.missingActiveRatio, 0, "Even sub-percent missing speech is a regression")
                if !continuity.passed {
                    continuityFailures.append("\(scenario.id): matched=\(continuity.matchedWindowRatio), missing=\(continuity.missingActiveRatio), longest=\(continuity.longestMissingSeconds)s")
                }
            }
            try await barrier.meet("measured-" + scenario.id)
        }
        // Report a normal failed test after collecting every condition. With
        // continueAfterFailure=false, XCTest aborts this async Swift test host
        // and adds an unrelated "runner exited with code 75" failure.
        continueAfterFailure = true
        XCTAssertTrue(continuityFailures.isEmpty, "Speech continuity failed: " + continuityFailures.joined(separator: "; "))
    }

    private func waitForFirstParticipant(at worker: URL, room: String, token: String, timeout: Int) async throws {
        let url = worker.appendingPathComponent("api/rooms/\(room)/test-waiting-participant")
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let state = try? JSONDecoder().decode([String: Bool].self, from: data), state["ready"] == true {
                return
            }
            try await Task.sleep(for: timeout > 45 ? .seconds(1) : .milliseconds(150))
        }
        throw NSError(domain: "AudioE2E.WaitingParticipant", code: 1)
    }

    @MainActor
    private func leaveForSettingsAfterStartingCall(viewModel: IntercomViewModel, joiningStarted: ContinuousClock.Instant) async throws {
        #if os(iOS)
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        let settings = try XCTUnwrap(URL(string: UIApplication.openSettingsURLString))
        let wasAudioReady = viewModel.isAudioReady
        let opened = await UIApplication.shared.open(settings)
        XCTAssertTrue(opened)
        try await waitUntil(seconds: 5, description: "Settings brings the call application into the OS background",
                            status: { "state=\(UIApplication.shared.applicationState.rawValue)" }) {
            UIApplication.shared.applicationState == .background
        }
        print("Audio E2E: Entered OS background after \(joiningStarted.duration(to: .now)); audio ready before opening Settings=\(wasAudioReady)")
        #else
        throw NSError(domain: "AudioE2E.BackgroundAfterStartRequiresIOS", code: 1)
        #endif
    }

    @MainActor
    private func checkBackgroundIfRequested(_ requested: Bool) {
        #if os(iOS)
        if requested { XCTAssertEqual(UIApplication.shared.applicationState, .background) }
        #endif
    }

    @MainActor
    private func verifyBackgroundQuietPeriod(
        viewModel: IntercomViewModel, barrier: AudioE2EBarrier, input: SpeechFileInput, probe: RenderedAudioProbe,
        route: RouteKind, peerID: String, groupID: UUID, role: String, transport: String,
        scenario: String, bothMute: Bool, keepMuted: Bool
    ) async throws {
        checkBackgroundIfRequested(true)
        let call = viewModel.currentCallReference
        let callDeadline = viewModel.callDisconnectDeadline
        if bothMute { XCTAssertTrue(viewModel.setCallMuted(true, for: call)) }
        else { input.setSilentInput(true) }
        defer { if !bothMute { input.setSilentInput(false) } }
        try await barrier.meet("\(scenario)-input")
        try await Task.sleep(for: .seconds(1)) // Let VAD release and buffers drain.
        probe.reset()
        let firstSent = viewModel.sentVoicePacketCount
        let firstReceived = viewModel.receivedVoicePacketCount
        let firstOutputBatchCount = observedOutputBatches(viewModel)
        let started = ProcessInfo.processInfo.systemUptime
        repeat {
            checkBackgroundIfRequested(true)
            XCTAssertEqual(viewModel.activeGroupID, groupID)
            XCTAssertEqual(viewModel.availableCallRoutes, [route])
            XCTAssertEqual(viewModel.authenticatedPeerIDs, [peerID])
            XCTAssertTrue(viewModel.isAudioReady)
            XCTAssertTrue(viewModel.isCallMediaStarted)
            if bothMute { XCTAssertTrue(viewModel.effectiveInputMuted) }
            else { XCTAssertEqual(viewModel.audioPipeline.vadRuntimeSnapshot.state, .silence) }
            try await Task.sleep(for: .seconds(1))
        } while ProcessInfo.processInfo.systemUptime - started < 60
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
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "endpoint-\(role)-\(scenario)-measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await barrier.meet("\(scenario)-observed")
        if bothMute, !keepMuted, role == "b" { XCTAssertTrue(viewModel.setCallMuted(false, for: call)) }
        print("Audio E2E: Both endpoints kept the call during \(duration) seconds in \(scenario); peak=\(peak) tx=\(transmitted) rx=\(received) outputBatches=\(outputBatches)")
    }

    @MainActor
    private func verifyBackgroundInternetRecovery(
        viewModel: IntercomViewModel, workerURL: URL, room: String, token: String,
        groupID: UUID, peerID: String, participantID: String
    ) async throws {
        func signalOutage(_ phase: String) async throws {
            let url = workerURL.appendingPathComponent("api/rooms/\(room)/test-internet-outage-\(phase)")
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["participantId": participantID])
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
            guard status == 200 else { throw NSError(domain: "AudioE2E.InternetOutage.\(phase)", code: status) }
        }
        func status() -> String {
            "routes=\(viewModel.availableCallRoutes) state=\(viewModel.connectionState) peers=\(viewModel.authenticatedPeerIDs.count) audioReady=\(viewModel.isAudioReady)"
        }
        checkBackgroundIfRequested(true)
        let callDeadline = viewModel.callDisconnectDeadline
        try await signalOutage("ready")
        try await waitUntil(seconds: 25, description: "The Internet route and authenticated peer are lost in the background", status: status) {
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
        try await waitUntil(seconds: 45, description: "The same call recovers its authenticated peer and media in the background", status: status) {
            viewModel.availableCallRoutes == [.webRTC] && viewModel.authenticatedPeerIDs == [peerID]
                && viewModel.isCallMediaStarted && viewModel.isAudioReady
                && IntercomViewModel.admittedMemberships(in: viewModel.peerProfiles).count == 1
        }
        checkBackgroundIfRequested(true)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        XCTAssertEqual(viewModel.callDisconnectDeadline, callDeadline)
        print("Audio E2E: Recovered authenticated Internet media in the background after \(outageObserved.duration(to: .now))")
    }

    #if DEBUG
    @MainActor
    private func verifyBackgroundLocalRecovery(
        viewModel: IntercomViewModel, routes: MixedRouteAudioE2E, barrier: AudioE2EBarrier,
        groupID: UUID, peerID: String, expectsMediaDuringRecovery: Bool
    ) async throws {
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
        try await waitUntil(seconds: 2, description: "The Local route drops in the background", status: { viewModel.routeLabel }) {
            viewModel.availableCallRoutes.isEmpty
        }
        try await Task.sleep(for: .milliseconds(200))
        let packetsAtLoss = viewModel.receivedVoicePacketCount
        try await Task.sleep(for: .milliseconds(500))
        checkBackgroundIfRequested(true)
        XCTAssertTrue(viewModel.availableCallRoutes.isEmpty)
        XCTAssertTrue(viewModel.isAudioReady)
        XCTAssertEqual(viewModel.receivedVoicePacketCount, packetsAtLoss)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        print("Audio E2E: Observed Local listener loss without leaving the background")

        try await waitUntil(seconds: 20, description: "The same call regains its Local route in the background", status: { viewModel.routeLabel }) {
            viewModel.availableCallRoutes == [.multipeer] && viewModel.authenticatedPeerIDs == [peerID]
                && viewModel.isAudioReady && viewModel.isCallMediaStarted
        }
        let replacement = try await routes.currentLocalMedia()
        XCTAssertFalse(replacement === oldMedia)
        let peer = PeerID(rawValue: peerID)
        try await waitUntil(seconds: 10, description: "Replacement Local UDP is ready", status: { viewModel.routeLabel }) {
            replacement.isReady(for: peer) && (!expectsMediaDuringRecovery || (replacement.statistics.receivedMediaDatagrams ?? 0) > 0)
        }
        checkBackgroundIfRequested(true)
        XCTAssertEqual(viewModel.activeGroupID, groupID)
        XCTAssertEqual(viewModel.callDisconnectDeadline, callDeadline)
        print("Audio E2E: Recovered Local media with a new listener in the background after \(outageStarted.duration(to: .now))")
    }
    #endif

    @MainActor
    private func verifyPairedAudio(
        viewModel: IntercomViewModel, barrier: AudioE2EBarrier, probe: RenderedAudioProbe,
        scenario: String, route: RouteKind, transport: String, role: String,
        local: [Float], remote: [Float], directory: URL, seconds: Double, movesToBackground: Bool,
        expectsRemoteSpeech: Bool = true
    ) async throws {
        try await waitUntil(seconds: 12, description: "Media starts for \(scenario)", status: { viewModel.routeLabel }) {
            viewModel.isCallMediaStarted
        }
        try await barrier.meet("\(scenario)-ready")
        checkBackgroundIfRequested(movesToBackground)
        probe.reset()
        let firstReceived = viewModel.receivedVoicePacketCount
        try await Task.sleep(for: .seconds(seconds))
        let rendered = probe.snapshot()
        checkBackgroundIfRequested(movesToBackground)
        let received = viewModel.receivedVoicePacketCount - firstReceived
        XCTAssertEqual(viewModel.availableCallRoutes, [route])
        XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1)
        XCTAssertNil(viewModel.audioErrorMessage)
        try await barrier.meet("\(scenario)-measured")
        let (remoteMatch, localMatch) = await Task.detached {
            (RenderedAudioProbe.speechMatch(reference: remote, referenceRate: 48000, output: rendered.samples, outputRate: rendered.rate),
             RenderedAudioProbe.speechMatch(reference: local, referenceRate: 48000, output: rendered.samples, outputRate: rendered.rate))
        }.value
        XCTAssertEqual(rendered.invalid, 0)
        XCTAssertGreaterThan(rendered.samples.count, Int(rendered.rate * seconds * 0.8))
        if expectsRemoteSpeech {
            XCTAssertGreaterThan(received, 20)
            XCTAssertGreaterThan(remoteMatch, 0.45, "The matched output must include remote speech for \(scenario)")
            XCTAssertGreaterThan(remoteMatch, localMatch + 0.10, "The local fixture cannot satisfy the remote speech oracle")
        } else {
            XCTAssertEqual(received, 0, "The listening endpoint must stay muted")
            XCTAssertLessThan(rendered.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.001)
        }
        let evidence: [String: Any] = ["scenario": scenario, "role": role, "transport": transport,
            "background": movesToBackground, "expectsRemoteSpeech": expectsRemoteSpeech,
            "received": received, "remoteMatch": remoteMatch, "localMatch": localMatch,
            "renderedSamples": rendered.samples.count, "renderedRate": rendered.rate]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence), uniformTypeIdentifier: "public.json")
        attachment.name = "endpoint-\(role)-\(scenario)-measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = directory.appendingPathComponent("\(scenario)-\(role).wav")
        try await Task.detached { try probe.writeWAV(to: wav, rendered: rendered) }.value
        let recording = XCTAttachment(contentsOfFile: wav)
        recording.name = "endpoint-\(role)-\(scenario)-speech"
        recording.lifetime = .keepAlways
        add(recording)
    }

    @MainActor
    private func sendToStandaloneReceiver(viewModel: IntercomViewModel, invitation: URL,
                                          directory: URL, seconds: Double) async throws {
        XCTAssertTrue((6...20).contains(seconds))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let invitationFile = directory.appendingPathComponent("receiver-invitation.url")
        let joinCommand = directory.appendingPathComponent("join")
        try Data(invitation.absoluteString.utf8).write(to: invitationFile, options: .atomic)
        FileHandle.standardOutput.write(Data("AUDIO_E2E_STANDALONE_INVITE_READY\n".utf8))
        // The operator releases the sender only after the receiving app has been
        // in the intended OS state for the required duration.
        try await waitUntil(seconds: 600, description: "Standalone receiver wait", status: { "join command missing" }) {
            FileManager.default.fileExists(atPath: joinCommand.path)
        }
        try viewModel.acceptInviteURL(invitation)
        try await waitUntil(seconds: 45, description: "Authenticated standalone receiver",
                            status: { viewModel.routeLabel }) {
            viewModel.availableCallRoutes == [.multipeer] && viewModel.authenticatedPeerIDs.count == 1
                && viewModel.isAudioReady && viewModel.isCallMediaStarted
        }
        let call = viewModel.currentCallReference
        let packets = viewModel.sentVoicePacketCount
        let adapter = try XCTUnwrap(viewModel.callSession as? RideIntercomCallSessionAdapter)
        let queuedDropsBeforeSpeech = adapter.droppedAudioPacketCount
        func localDatagramsSent(_ diagnostics: RTCNetworkDiagnostics?) -> UInt64? {
            diagnostics?.routes.first { $0.route == .multipeer }?.statistics.sentMediaDatagrams
        }
        let diagnosticsBeforeSpeech = viewModel.networkDiagnostics
        let startedAt = Date().timeIntervalSince1970
        try await Task.sleep(for: .seconds(seconds))
        XCTAssertEqual(viewModel.currentCallReference, call)
        XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1)
        XCTAssertGreaterThan(viewModel.sentVoicePacketCount, packets)
        let diagnosticsAfterSpeech = try XCTUnwrap(viewModel.networkDiagnostics)
        let datagramsAfterSpeech = try XCTUnwrap(localDatagramsSent(diagnosticsAfterSpeech))
        XCTAssertGreaterThan(datagramsAfterSpeech, localDatagramsSent(diagnosticsBeforeSpeech) ?? 0)
        let evidence: [String: Any] = ["startedAt": startedAt, "endedAt": Date().timeIntervalSince1970,
            "sentVoicePackets": viewModel.sentVoicePacketCount - packets,
            "senderQueueDropsDuringSpeech": adapter.droppedAudioPacketCount - queuedDropsBeforeSpeech,
            "localDatagramsBeforeSpeech": localDatagramsSent(diagnosticsBeforeSpeech) as Any? ?? NSNull(),
            "localDatagramsAfterSpeech": datagramsAfterSpeech,
            "localSampleBeforeSpeechAt": diagnosticsBeforeSpeech?.generatedAt as Any? ?? NSNull(),
            "localSampleAfterSpeechAt": diagnosticsAfterSpeech.generatedAt]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence), uniformTypeIdentifier: "public.json")
        attachment.name = "standalone-sender-observation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitUntil(seconds: Double, description: String, status: () -> String, condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition(), start.duration(to: .now) < .seconds(seconds) { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else {
            XCTFail("\(description) timed out: \(status())")
            throw NSError(domain: "AudioE2E", code: 1)
        }
    }
}

#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
extension AudioE2ETests {
    /// Native capture clock and output with fixture PCM at the microphone boundary.
    /// Compares the post-TX recording with output over two runs; it does not
    /// compare the fixture waveform with the processed recording.
    @MainActor
    func testRecordingCheckPreservesWholeSpeechAcrossNativePlaybackAndRestart() async throws {
        let namespace = "RideIntercom.AudioE2E.AudioCheck." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let keychain = FixtureKeychain()
        let credentials = KeychainGroupCredentialStore(keychain: keychain, namespace: namespace)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        defer {
            defaults.removePersistentDomain(forName: namespace)
            for ref in (try? credentials.references()) ?? [] { try? credentials.delete(reference: ref) }
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = AVAudioEngine()
        let input = try SpeechFileInput(name: "speech-ja", engine: engine)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        let account = AppleAccountSession(keychain: keychain, defaults: defaults, namespace: namespace,
            credentialState: { _ in .authorized })
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        XCTAssertTrue(account.completeSignIn(userID: "audio-check-e2e", state: request.state))
        let settings = UserDefaultsAppSettingsStore(defaults: defaults)
        settings.save(AppSettings())
        let vm = IntercomViewModel(accountSession: account, enforceCallAccess: false,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials),
            appSettingsStore: settings,
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: namespace),
            localMemberIdentityStore: UserDefaultsLocalMemberIdentityStore(defaults: defaults),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: namespace),
            requestMicrophoneAccess: { await AVAudioApplication.requestRecordPermission() },
            audioInputCapture: AudioInputStreamCapture(configuration: .intercom(
                voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()), backend: input),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: output))
        defer { vm.cancelAudioCheck(); vm.audioPipeline.onOutputFrame = nil }
        XCTAssertFalse(vm.isMuted)
        XCTAssertTrue(vm.isSoundIsolationEnabled)
        var rows: [[String: Any]] = []
        for cycle in 1...2 {
            var observation = AudioCheckValidationObservation(generation: UUID())
            var referenceInstalled = false
            var renderDrops = 0
            var inputDrops: Int?
            vm.startAudioCheck()
            let original = vm.audioPipeline.onOutputFrame
            vm.audioPipeline.onOutputFrame = { frame in
                original?(frame)
                guard vm.audioCheckPhase == .playing else { return }
                if !referenceInstalled, let frames = try? vm.audioCheckRecording?.recordedFrames() {
                    observation.setInput(frames)
                    referenceInstalled = true
                }
                observation.appendOutput(frame)
                renderDrops = max(renderDrops, vm.audioPipeline.droppedRenderFrameCount)
                if let count = vm.inputFrameDelivery?.droppedFrameCount {
                    inputDrops = max(inputDrops ?? 0, count)
                }
            }
            let started = ContinuousClock.now
            while vm.audioCheckPhase.isInProgress, started.duration(to: .now) < .seconds(15) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(vm.audioCheckPhase, .completed, vm.audioCheckStatusMessage)
            XCTAssertEqual(vm.audioCheckRecordedFrameCount, 240_000)
            XCTAssertFalse(vm.hasAnyActiveGroupConnection)
            XCTAssertFalse(engine.isRunning)
            XCTAssertTrue(input.captureDiscontinuities.isEmpty, "Native capture must not omit fixture time")
            XCTAssertNotNil(inputDrops, "Input delivery drop count must be sampled during playback")
            XCTAssertEqual(inputDrops, 0)
            var row = observation.record(phase: vm.audioCheckPhase.rawValue, drops: renderDrops, inputDrops: inputDrops ?? -1,
                inputStopped: !engine.isRunning, outputStopped: !engine.isRunning,
                nativeBackends: false, watchRoute: false, engineRunning: engine.isRunning)
            row["cycle"] = cycle
            row["nativeCaptureClock"] = true
            row["nativeOutput"] = true
            row["microphonePCMReplacedByFixture"] = true
            row["comparisonReference"] = "Post-TX decoded recording, not the original fixture"
            rows.append(row)
            XCTAssertEqual(row["comparison"] as? String, "measured")
            XCTAssertEqual(row["fullCoverage"] as? Bool, true)
            XCTAssertGreaterThanOrEqual(row["fullSignalCorrelation"] as? Double ?? -1, 0.99)
            XCTAssertLessThanOrEqual(row["fullSignalNormalizedRMSError"] as? Double ?? 1, 0.01)
            XCTAssertLessThanOrEqual(row["silentResidualRMS"] as? Double ?? 1, 0.00001)
            XCTAssertEqual(renderDrops, 0)
            vm.audioPipeline.onOutputFrame = original
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Audio Check native speech recording two cycles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
