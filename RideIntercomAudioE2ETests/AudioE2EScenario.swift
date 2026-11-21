import Foundation
import AudioMixer
import Codec
import RTC
import SessionManager
import VADGate
import XCTest
@testable import RideIntercom

struct AudioE2EScenario: Codable {
    let id: String
    var codec: String
    let format: String
    let bitRate: Int
    let profile: String
    let speaker: Bool
    let vad: String
    var transmitIsolation: Bool
    let receiveMixIsolation: Bool
    let peerIsolation: Bool
    let duck: Bool
    let receiveMixVolume: Float
    let peerVolume: Float
    let localMute: Bool
    let outputMute: Bool
    let seconds: Double

    private enum CodingKeys: String, CodingKey {
        case id, codec, format, bitRate, profile, speaker, vad, transmitIsolation, peerIsolation
        case duck, peerVolume, localMute, outputMute, seconds
        case receiveMixIsolation = "masterIsolation"
        case receiveMixVolume = "masterVolume"
    }

    var expectsSilence: Bool { localMute || outputMute || receiveMixVolume == 0 || peerVolume == 0 }

    private var wantsSpeaker: Bool {
        #if os(iOS)
        speaker || profile == "speakerDefault"
        #else
        // macOS exposes CoreAudio device IDs, not iOS's built-in-speaker port.
        // Keep the counterpart on its real default device while iOS changes route.
        false
        #endif
    }

    @MainActor
    func apply(to model: IntercomViewModel, peerID: String) throws {
        let rate = try XCTUnwrap(RTCAudioFormatPreset(rawValue: format))
        let session = try XCTUnwrap(AudioSessionProfile(rawValue: profile))
        let sensitivity = try XCTUnwrap(VoiceActivitySensitivity(rawValue: vad))
        let requested = AudioCodecIdentifier(rawValue: codec)
        guard [.pcm16, .opus, .mpeg4AACELD, .mpeg4AACELDv2].contains(requested) else {
            throw NSError(domain: "AudioE2E.UnknownCodec", code: 1)
        }
        if model.rtcAudioFormatPreset != rate { model.setRTCAudioFormatPreset(rate) }
        if model.preferredTransmitCodec != requested { model.setPreferredTransmitCodec(requested) }
        if codec == "opus", model.opusBitRate != bitRate { model.setOpusBitRate(bitRate) }
        if ["mpeg4AACELD", "mpeg4AACELDv2"].contains(codec), model.aacELDv2BitRate != bitRate {
            model.setAACELDv2BitRate(bitRate)
        }
        applySessionSettings(to: model, session: session)
        if model.vadSensitivity != sensitivity { model.setVADSensitivity(sensitivity) }
        applyMixSettings(to: model, peerID: peerID)
    }

    @MainActor
    private func applySessionSettings(to model: IntercomViewModel, session: AudioSessionProfile) {
        // Exercise the same independent controls as Settings, including speaker
        // with Stream mode and both explicit Echo Cancellation preferences.
        if model.audioSessionModeProfile != session.settingsModeProfile {
            model.setAudioSessionModeProfile(session.settingsModeProfile)
        }
        if session.mode == .default,
           model.audioSessionProfile.prefersEchoCancelledInput != session.prefersEchoCancelledInput {
            if model.isSpeakerOutputEnabled { model.setSpeakerOutputEnabled(false) }
            model.setSessionEchoCancellationEnabled(session.prefersEchoCancelledInput)
        }
        if model.isSpeakerOutputEnabled != wantsSpeaker { model.setSpeakerOutputEnabled(wantsSpeaker) }
    }

    @MainActor
    private func applyMixSettings(to model: IntercomViewModel, peerID: String) {
        if model.isSoundIsolationEnabled != transmitIsolation { model.setSoundIsolationEnabled(transmitIsolation) }
        if model.receiveMixSoundIsolationEnabled != receiveMixIsolation {
            model.setReceiveMixSoundIsolationEnabled(receiveMixIsolation)
        }
        if model.isRemoteSoundIsolationEnabled(peerID: peerID) != peerIsolation {
            model.setRemoteSoundIsolationEnabled(peerID: peerID, enabled: peerIsolation)
        }
        if model.isDuckOthersEnabled != duck { model.setDuckOthersEnabled(duck) }
        model.setOverallOutputVolume(receiveMixVolume)
        model.setRemoteOutputVolume(peerID: peerID, volume: peerVolume)
        if model.isMuted != localMute { model.toggleMute() }
        if model.isOutputMuted != outputMute { model.toggleOutputMute() }
    }

    @MainActor
    func verifyApplied(to model: IntercomViewModel, peerID: String) {
        XCTAssertEqual(model.preferredTransmitCodec.rawValue, codec)
        XCTAssertEqual(model.rtcAudioFormatPreset.rawValue, format)
        guard let session = AudioSessionProfile(rawValue: profile) else {
            XCTFail("Unknown session profile: \(profile)"); return
        }
        XCTAssertEqual(model.audioSessionModeProfile, session.settingsModeProfile)
        XCTAssertEqual(model.isSpeakerOutputEnabled, wantsSpeaker)
        let sessionReport = model.lastAudioSessionConfigurationReport
        XCTAssertEqual(sessionReport?.requestedConfiguration.mode, session.mode)
        XCTAssertEqual(sessionReport?.requestedConfiguration.defaultToSpeaker, wantsSpeaker)
        XCTAssertEqual(
            sessionReport?.requestedConfiguration.prefersEchoCancelledInput, session.prefersEchoCancelledInput
        )
        for operation in sessionReport?.operations ?? [] {
            if case .failed = operation.result { XCTFail("\(id): \(operation)") }
        }
        verifyCodecAndVAD(on: model)
        let buses = model.audioPipeline.snapshot.buses
        XCTAssertEqual(buses.first(where: { $0.id == "rx-master" })?.volume, outputMute ? 0 : receiveMixVolume)
        XCTAssertEqual(model.remoteOutputVolumes[peerID] ?? 1, peerVolume)
        XCTAssertEqual(model.lastInputStreamOperationReport?.snapshot.isRunning, true)
        let voiceProcessing = model.lastVoiceProcessingOperationReport?.snapshot.inputVoiceProcessing
        XCTAssertEqual(voiceProcessing?.otherAudioDuckingEnabled, duck)
        XCTAssertEqual(model.lastVoiceProcessingOperationReport?.snapshot.inputVoiceProcessing?.inputMuted, localMute)
        #if os(iOS)
        XCTAssertEqual(model.lastVoiceProcessingOperationReport?.result, .applied)
        #endif
        func effect(_ busID: String, _ effectID: String, active: Bool) {
            guard let bus = buses.first(where: { $0.id == busID }),
                  let effect = bus.effectChain.first(where: { $0.id == effectID }) else {
                XCTFail("Missing real AudioUnit: \(busID)/\(effectID)"); return
            }
            XCTAssertEqual(effect.state, active ? .active : .bypassed, "\(id): \(busID)/\(effectID)")
        }
        effect("tx-bus", "sound-isolation", active: transmitIsolation)
        effect("tx-bus", "dynamics-processor", active: true)
        effect("tx-bus", "peak-limiter", active: true)
        effect("rx-master", "sound-isolation", active: receiveMixIsolation)
        effect("rx-peer-\(peerID)", "sound-isolation", active: peerIsolation)
        effect("rx-output", "peak-limiter", active: true)
    }
    @MainActor
    private func verifyCodecAndVAD(on model: IntercomViewModel) {
        XCTAssertEqual(model.vadGateRuntimeSnapshot.configuration, model.vadSensitivity.configuration)
        let report = model.audioPipeline.codecRuntimeReport
        XCTAssertEqual(report.requestedConfiguration.codec.rawValue, codec)
        XCTAssertEqual(report.requestedConfiguration.format, model.rtcAudioFormatPreset.audioFormat)
        if codec != "pcm16" { XCTAssertEqual(report.requestedConfiguration.activeBitRate, bitRate) }
        XCTAssertEqual(model.selectedTransmitCodec.rawValue, report.selectedCodec.rawValue)
        XCTAssertEqual(report.isFallback, report.selectedCodec.rawValue != codec)
        if codec != "mpeg4AACELDv2" { XCTAssertFalse(report.isFallback) }
        if report.isFallback {
            XCTAssertFalse(report.availableCodecs.map(\.rawValue).contains(codec))
            XCTAssertEqual(report.selectedCodec.rawValue, "pcm16")
        }
    }

}

struct AudioE2ENetworkRun {
    let scenarios: [AudioE2EScenario]
    let initial: AudioE2EScenario
    let identifier: String
    let role: String
    let groupID: UUID
    let transport: String
    let startsFromSavedGroup: Bool
    let waitsForInternet: Bool
    let standaloneReceiver: Bool
    let startsBeforeInternet: Bool
    let waitsForLateParticipant: Bool
    let movesToBackground: Bool
    let checksInternetRecovery: Bool
    let checksLocalRecovery: Bool
    let checksBackgroundSilence: Bool
    let checksBackgroundMute: Bool
    let mutedWait: Int
    let workerURL: String?
    let speechPair: String?

    var mixed: Bool { transport == "mixed" }
    var usesInternet: Bool { transport == "webrtc" || mixed || waitsForInternet }
    var recovery: Bool { checksInternetRecovery || checksLocalRecovery }
    var soleRoute: RouteKind { usesInternet ? .webRTC : .multipeer }
    var groupSecret: String { "fixture-only-\(identifier)" }
    var memberID: String { "e2e-\(role)-\(identifier.prefix(8))" }
    var enabledRoutes: Set<RouteKind> {
        if mixed || waitsForInternet { return [.multipeer, .webRTC] }
        return transport == "webrtc" ? [.webRTC] : [.multipeer]
    }

    init(environment env: [String: String]) throws {
        let scenarioData = try XCTUnwrap(env["AUDIO_E2E_SCENARIOS"]?.data(using: .utf8))
        scenarios = try JSONDecoder().decode([AudioE2EScenario].self, from: scenarioData)
        initial = try XCTUnwrap(scenarios.first)
        identifier = try XCTUnwrap(env["AUDIO_E2E_RUN"], "Run scripts/audio_e2e.py; a second endpoint is required")
        role = try XCTUnwrap(env["AUDIO_E2E_ROLE"])
        XCTAssertTrue(["a", "b"].contains(role))
        groupID = try XCTUnwrap(UUID(uuidString: identifier))
        transport = env["AUDIO_E2E_TRANSPORT"] ?? "local"
        startsFromSavedGroup = env["AUDIO_E2E_SAVED_GROUP_START"] == "1"
        waitsForInternet = env["AUDIO_E2E_UNANSWERED_INTERNET"] == "1"
        standaloneReceiver = env["AUDIO_E2E_STANDALONE_RECEIVER"] == "1"
        startsBeforeInternet = env["AUDIO_E2E_DELAY_INTERNET"] == "1"
        waitsForLateParticipant = env["AUDIO_E2E_WAIT_FOR_LATE_PARTICIPANT"] == "1"
        movesToBackground = env["AUDIO_E2E_BACKGROUND_AFTER_START"] == "1"
        checksInternetRecovery = env["AUDIO_E2E_BACKGROUND_INTERNET_RECOVERY"] == "1"
        checksLocalRecovery = env["AUDIO_E2E_BACKGROUND_LOCAL_RECOVERY"] == "1"
        checksBackgroundSilence = env["AUDIO_E2E_BACKGROUND_SILENCE"] == "1"
        checksBackgroundMute = env["AUDIO_E2E_BACKGROUND_MIC_OFF"] == "1"
        mutedWait = env["AUDIO_E2E_BACKGROUND_MUTED_WAIT_SECONDS"].map { Int($0) ?? -1 } ?? 0
        workerURL = env["AUDIO_E2E_WORKER_URL"]
        speechPair = env["AUDIO_E2E_SPEECH_PAIR"]
    }

    func verifyConfiguration() {
        XCTAssertTrue((0...300).contains(mutedWait))
        if standaloneReceiver {
            XCTAssertTrue(role == "b" && transport == "local" && !waitsForLateParticipant && !movesToBackground
                && !recovery && !checksBackgroundMute && !checksBackgroundSilence && mutedWait == 0)
            XCTAssertEqual(scenarios.count, 1)
        }
        if mutedWait > 0 { XCTAssertTrue(checksBackgroundMute && recovery) }
        if startsFromSavedGroup {
            XCTAssertTrue(transport == "local" && !standaloneReceiver && !waitsForLateParticipant)
        }
        if waitsForInternet {
            XCTAssertTrue(startsFromSavedGroup && scenarios.count == 1 && initial.seconds <= 10)
        }
        if waitsForLateParticipant { XCTAssertTrue(["local", "webrtc"].contains(transport)) }
        if startsBeforeInternet { XCTAssertTrue(mixed) }
        verifyBackgroundConfiguration()
    }

    private func verifyBackgroundConfiguration() {
        if movesToBackground { XCTAssertTrue(waitsForLateParticipant) }
        if checksInternetRecovery {
            XCTAssertTrue(movesToBackground && waitsForLateParticipant && transport == "webrtc")
        }
        if checksLocalRecovery { XCTAssertTrue(movesToBackground && waitsForLateParticipant && transport == "local") }
        if checksBackgroundSilence || checksBackgroundMute {
            XCTAssertTrue(movesToBackground && waitsForLateParticipant)
            if recovery { XCTAssertTrue(checksBackgroundMute && mutedWait > 0) }
            XCTAssertFalse(checksBackgroundSilence && checksBackgroundMute)
        }
    }
}
