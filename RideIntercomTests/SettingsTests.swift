import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SessionManager
import SoundIsolation
import Testing
import VADGate

@testable import RideIntercom

extension AppTests {
    @MainActor
    struct SettingsTests {
        @Test func transmitIsolationSurvivesRelaunchAndModeChangesUntilReset() throws {
            let suite = "RideIntercomTests.transmit-isolation.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = UserDefaultsAppSettingsStore(defaults: defaults)
            let initial = AppTestSupport.makeHarness(appSettingsStore: store).viewModel

            #expect(initial.interfaceMode == .standard)
            #expect(initial.isSoundIsolationEnabled)
            initial.setSoundIsolationEnabled(false)

            let relaunched = AppTestSupport.makeHarness(appSettingsStore: store).viewModel
            #expect(!relaunched.isSoundIsolationEnabled)
            #expect(!relaunched.currentAudioPipelineConfiguration().transmitSoundIsolationEnabled)
            relaunched.setInterfaceMode(.advanced)
            #expect(!relaunched.isSoundIsolationEnabled)

            let advanced = AppTestSupport.makeHarness(appSettingsStore: store).viewModel
            #expect(advanced.interfaceMode == .advanced)
            #expect(!advanced.isSoundIsolationEnabled)
            advanced.resetAllSettings()
            #expect(advanced.isSoundIsolationEnabled)
            #expect(advanced.interfaceMode == .advanced)

            let afterReset = AppTestSupport.makeHarness(appSettingsStore: store).viewModel
            #expect(afterReset.isSoundIsolationEnabled)
            #expect(afterReset.currentAudioPipelineConfiguration().transmitSoundIsolationEnabled)
            #expect(afterReset.interfaceMode == .advanced)
        }

        @Test(arguments: [nil, "unrecognized-profile", AudioSessionProfile.voiceChat.rawValue] as [String?])
        func audioSessionUsesTheStoredModeAndResetsWithoutReapplyingStream(savedMode: String?) async throws {
            let suite = "RideIntercomTests.initial-audio-mode.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(savedMode, forKey: "RideIntercom.settings.audioSessionProfile")
            let store = UserDefaultsAppSettingsStore(defaults: defaults)
            let harness = AppTestSupport.makeHarness(appSettingsStore: store)
            let viewModel = harness.viewModel
            defer { viewModel.disconnect() }

            let hasSavedStream = savedMode == AudioSessionProfile.voiceChat.rawValue
            viewModel.setInterfaceMode(.advanced)
            viewModel.setInterfaceMode(.standard)
            #expect(viewModel.audioSessionModeProfile == (hasSavedStream ? .voiceChat : .standard))
            viewModel.selectGroup(try #require(viewModel.groups.first))
            harness.callSession.authenticate(["member-108"])
            await AppTestSupport.waitUntil { viewModel.isAudioReady }
            #expect(viewModel.isAudioReady)
            let initial = try #require(harness.audioSessionBackend.appliedConfigurations.last)
            #expect(initial.mode == (hasSavedStream ? .voiceChat : .default))
            #expect(initial.prefersEchoCancelledInput == (hasSavedStream ? nil : true))
            #expect(!initial.options.contains(.defaultToSpeaker))

            viewModel.setAudioSessionModeProfile(.voiceChat)
            viewModel.setSpeakerOutputEnabled(true)
            let beforeReset = harness.audioSessionBackend.appliedConfigurations.count
            viewModel.resetAllSettings()
            let appliedByReset = harness.audioSessionBackend.appliedConfigurations.dropFirst(beforeReset)
            #expect(!appliedByReset.isEmpty)
            #expect(appliedByReset.allSatisfy { $0.mode == .default })
            #expect(appliedByReset.last?.prefersEchoCancelledInput == true)
            #expect(appliedByReset.last?.options.contains(.defaultToSpeaker) == false)
            #expect(store.load().audioSessionProfile == .echoCancelledInput)
        }

        @Test func unchangedEncodingSettingsDoNotRepublishRTCPPolicy() {
            let harness = AppTestSupport.makeHarness()
            let policies = harness.callSession.audioPolicies
            for _ in 0..<100 {
                harness.viewModel.setPreferredTransmitCodec(harness.viewModel.preferredTransmitCodec)
                harness.viewModel.setRTCAudioFormatPreset(harness.viewModel.rtcAudioFormatPreset)
                harness.viewModel.setAACELDv2BitRate(harness.viewModel.aacELDv2BitRate)
                harness.viewModel.setOpusBitRate(harness.viewModel.opusBitRate)
            }
            #expect(harness.callSession.audioPolicies == policies)
        }

        @Test func viewModelAppliesOutputSettingsThroughAudioMixer() async {
            let harness = AppTestSupport.makeHarness()

            harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
            harness.callSession.authenticate(["member-108"])
            await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
            harness.viewModel.setMasterOutputVolume(2)
            let activeOutputBus = harness.viewModel.audioPipeline.snapshot.buses.first {
                $0.id == "rx-master"
            }
            harness.viewModel.toggleOutputMute()
            let mutedOutputBus = harness.viewModel.audioPipeline.snapshot.buses.first { $0.id == "rx-master" }

            #expect(activeOutputBus?.volume == 2)
            #expect(mutedOutputBus?.volume == 0)
        }

        @Test func codecUISelectsAnActualAACBitrateWithoutPCMFallback() {
            let harness = AppTestSupport.makeHarness()

            #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELD)
            #expect(harness.viewModel.aacELDv2BitRate == 48_000)
            #expect(harness.viewModel.opusBitRate == 48_000)
            #expect(
                harness.callSession.audioPolicies.last?.preferredCodecs.first
                    == AppAudioCodecBridge.selectedRTCCodec(.mpeg4AACELD))
            #expect(
                harness.callSession.audioPolicies.last?.preferredSendFormat
                    == RTC.RTCAudioFormat(audioFormat: .intercomPacketAudio))

            harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELD)
            harness.viewModel.setAACELDv2BitRate(11_000)
            harness.viewModel.setOpusBitRate(129_000)

            #expect(harness.viewModel.preferredTransmitCodec == .mpeg4AACELD)
            #expect(harness.viewModel.aacELDv2BitRate == 48_000)
            #expect(harness.viewModel.opusBitRate == 128_000)
            #expect(
                harness.callSession.audioPolicies.last?.preferredCodecs.first
                    == AppAudioCodecBridge.selectedRTCCodec(
                        .mpeg4AACELD,
                        options: AppAudioCodecOptions(aacELDv2BitRate: 48_000, opusBitRate: 128_000)
                    ))
        }

        @Test func viewModelAppliesAudioSessionMatrixProfilesThroughSessionManager() {
            let harness = AppTestSupport.makeHarness()

            #expect(harness.viewModel.audioSessionProfile == .echoCancelledInput)
            #expect(harness.viewModel.isSessionEchoCancellationEnabled)
            #expect(harness.viewModel.isDuckOthersEnabled)

            harness.viewModel.setSessionEchoCancellationEnabled(true)
            var applied = harness.audioSessionBackend.appliedConfigurations.last
            #expect(applied?.mode == .default)
            #expect(applied?.prefersEchoCancelledInput == true)
            #expect(applied?.options.contains(.defaultToSpeaker) == false)

            harness.viewModel.setSessionEchoCancellationEnabled(false)
            applied = harness.audioSessionBackend.appliedConfigurations.last
            #expect(applied?.mode == .default)
            #expect(applied?.prefersEchoCancelledInput == false)
            #expect(harness.viewModel.audioSessionProfile == .standard)

            harness.viewModel.setSpeakerOutputEnabled(true)
            applied = harness.audioSessionBackend.appliedConfigurations.last
            #expect(applied?.mode == .default)
            #expect(applied?.prefersEchoCancelledInput == true)
            #expect(applied?.options.contains(.defaultToSpeaker) == true)
            #expect(harness.viewModel.audioSessionProfile == .standard)

            harness.viewModel.setAudioSessionModeProfile(.voiceChat)
            harness.viewModel.setSpeakerOutputEnabled(true)
            applied = harness.audioSessionBackend.appliedConfigurations.last
            #expect(applied?.mode == .voiceChat)
            #expect(applied?.prefersEchoCancelledInput == nil)
            #expect(applied?.options.contains(.defaultToSpeaker) == true)
        }

        @Test func audioDeviceDefaultsDoNotPinTheStartupRoute() {
            let backend = FakeAudioSessionBackend()
            backend.current.currentInput = backend.current.availableInputs[1]
            backend.current.currentOutput = .builtInSpeaker
            let model = AppTestSupport.makeHarness(audioSessionManager: AudioSessionManager(backend: backend))
                .viewModel

            #expect(model.audioSessionSnapshot.currentInput == backend.current.currentInput)
            #expect(model.audioSessionSnapshot.currentOutput == .builtInSpeaker)
            #expect(model.selectedInputPort == .systemDefault)
            #expect(model.selectedOutputPort == .systemDefault)
            let requested = model.makeAudioSessionConfiguration()
            #expect(requested.preferredInput == .systemDefault)
            #expect(requested.preferredOutput == .systemDefault)
            #expect(!requested.defaultToSpeaker)
        }

        @Test func audioChoicesKeepAnAvailableDeviceAndFallBackWhenTheOtherIsGone() {
            let harness = AppTestSupport.makeHarness()
            let input = AudioPortInfo(id: "input-1", name: "Input 1")
            harness.viewModel.setInputPort(input)
            harness.viewModel.setOutputPort(.speaker)

            let renamedInput = AudioSessionDevice(
                id: .init(rawValue: input.id), name: "Helmet Mic", direction: .input)
            var snapshot = harness.audioSessionBackend.current
            snapshot.availableInputs = [.systemDefaultInput, renamedInput, renamedInput]
            snapshot.availableOutputs = []
            snapshot.currentInput = renamedInput
            snapshot.currentOutput = .systemDefaultOutput
            harness.viewModel.handleAudioSessionRuntimeEvent(
                .snapshotChanged(
                    .init(
                        reason: .routeChanged(.oldDeviceUnavailable), snapshot: snapshot)))

            let renamedPort = AudioPortInfo(device: renamedInput)
            #expect(harness.viewModel.availableInputPorts == [.systemDefault, renamedPort])
            #expect(harness.viewModel.selectedInputPort == renamedPort)
            #expect(harness.viewModel.availableOutputPorts == [.systemDefault])
            #expect(harness.viewModel.selectedOutputPort == .systemDefault)
            #expect(harness.viewModel.audioSessionSnapshot.currentInput == renamedInput)
            let requested = harness.viewModel.makeAudioSessionConfiguration()
            #expect(requested.preferredInput == .device(renamedInput.id))
            #expect(requested.preferredOutput == .systemDefault)
        }

        @Test func selectingAnAudioPortReconfiguresTheSessionAndRestartsActiveMedia() async {
            let harness = AppTestSupport.makeHarness()
            harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
            harness.callSession.authenticate(["member-108"])
            await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
            let input = AudioPortInfo(id: "input-1", name: "Input 1")

            var configured = harness.audioSessionBackend.appliedConfigurations.count
            harness.viewModel.setInputPort(input)
            #expect(harness.viewModel.selectedInputPort == input)
            #expect(harness.audioSessionBackend.appliedConfigurations.count > configured)
            #expect(!harness.viewModel.isAudioReady)
            await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }

            // The same port again reconfigures the session but keeps the running media.
            harness.viewModel.setInputPort(input)
            #expect(harness.viewModel.isAudioReady)

            configured = harness.audioSessionBackend.appliedConfigurations.count
            harness.viewModel.setOutputPort(.speaker)
            #expect(harness.viewModel.selectedOutputPort == .speaker)
            #expect(harness.audioSessionBackend.appliedConfigurations.count > configured)
            #expect(
                harness.audioSessionBackend.appliedConfigurations.last?.options.contains(.defaultToSpeaker)
                    == true)
            #expect(!harness.viewModel.isAudioReady)
            await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
            #expect(harness.viewModel.audioErrorMessage == nil)
        }

        @Test func viewModelLoadsAndPersistsAppAudioSettings() {
            let settingsStore = InMemoryAppSettingsStore(
                settings: AppSettings(
                    audioSessionProfile: .voiceChat,
                    vadSensitivity: .noisy,
                    preferredTransmitCodec: .opus,
                    rtcAudioFormatPreset: .mono16k,
                    aacELDv2BitRate: 11_000,
                    opusBitRate: 129_000
                ))
            let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore)

            #expect(harness.viewModel.audioSessionProfile == .voiceChat)
            #expect(harness.viewModel.vadSensitivity == .noisy)
            #expect(harness.viewModel.preferredTransmitCodec == .opus)
            #expect(harness.viewModel.rtcAudioFormatPreset == .mono16k)
            #expect(harness.viewModel.aacELDv2BitRate == 48_000)
            #expect(harness.viewModel.opusBitRate == 128_000)
            #expect(
                harness.callSession.audioPolicies.last?.preferredCodecs.first
                    == AppAudioCodecBridge.selectedRTCCodec(
                        .opus,
                        format: RTCAudioFormatPreset.mono16k.audioFormat,
                        options: AppAudioCodecOptions(aacELDv2BitRate: 48_000, opusBitRate: 128_000)
                    ))
            #expect(
                harness.callSession.audioPolicies.last?.preferredSendFormat
                    == RTC.RTCAudioFormat(audioFormat: RTCAudioFormatPreset.mono16k.audioFormat))

            harness.viewModel.setAudioSessionProfile(.echoCancelledInput)
            harness.viewModel.setVADSensitivity(.lowNoise)
            harness.viewModel.setPreferredTransmitCodec(.mpeg4AACELD)
            harness.viewModel.setRTCAudioFormatPreset(.mono24k)
            harness.viewModel.setAACELDv2BitRate(40_000)

            let saved = settingsStore.load()
            #expect(saved.audioSessionProfile == .echoCancelledInput)
            #expect(saved.vadSensitivity == .lowNoise)
            #expect(saved.preferredTransmitCodec == .mpeg4AACELD)
            #expect(saved.rtcAudioFormatPreset == .mono24k)
            #expect(saved.aacELDv2BitRate == 32_000)
            #expect(saved.opusBitRate == 128_000)
        }

    }
}
