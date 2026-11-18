#if os(iOS)
import AVFAudio
import SessionManager
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct NativeCallStartFailureTests {
    @Test(arguments: [InterfaceMode.standard, .advanced])
    func disabledNativeInputBecomesAnAudioFailureAndTheCallCanStillEnd(mode: InterfaceMode) async throws {
        let session = AVAudioSession.sharedInstance()
        let previousCategory = session.category, previousMode = session.mode, previousOptions = session.categoryOptions
        do {
            try session.setCategory(.playback, mode: .default)
            let activated = try await session.activate(options: [])
            try #require(activated)
            let engine = AVAudioEngine()
            let hardware = engine.inputNode.inputFormat(forBus: 0)
            try #require(hardware.sampleRate == 0 || hardware.channelCount == 0)
            let h = AppTestSupport.makeHarness(enforceCallAccess: false)
            // Microphone permission, activation/control and RTC are fixtures. The shared receive graph,
            // native input, voice processing, failure report and App call path are real.
            let vm = IntercomViewModel(accountSession: h.viewModel.accountSession, enforceCallAccess: false,
                callSession: h.callSession, groupRepository: h.viewModel.groupRepository,
                appSettingsStore: InMemoryAppSettingsStore(), internetSettingsStore: h.viewModel.internetSettingsStore,
                localMemberIdentityStore: InMemoryLocalMemberIdentityStore(identity: h.viewModel.localMemberIdentity),
                invitationAuthority: testInvitationAuthority(),
                requestMicrophoneAccess: { true },
                audioSessionManager: SessionManager.AudioSessionManager(backend: h.audioSessionBackend),
                audioInputCapture: AudioInputStreamCapture(configuration: .intercom(voiceProcessing:
                    IntercomViewModel.defaultVoiceProcessingConfiguration()), engine: engine),
                audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, engine: engine),
                callTicker: NoOpCallTicker())
            defer { vm.disconnect(); h.viewModel.disconnect() }
            vm.setInterfaceMode(mode); vm.setSoundIsolationEnabled(false)
            vm.selectGroup(try #require(vm.groups.first))
            await AppTestSupport.waitUntil { vm.audioErrorMessage != nil && vm.audioStartTask == nil }
            #expect(vm.lastInputStreamOperationReport?.result == .failed(.invalidFrame("Voice processing requires enabled input hardware")))
            #expect(vm.audioErrorMessage == "Microphone capture failed")
            #expect(vm.standardCallStatus == .audioUnavailable && vm.canDisconnectCall)
            #expect(!vm.isAudioReady && !vm.isCallMediaStarted && !engine.isRunning)
            #expect(h.callSession.startMediaCallCount == 0 && vm.callDisconnectDeadline != nil)
            vm.disconnect()
            #expect(vm.callDisconnectDeadline == nil && !vm.canDisconnectCall)
        } catch {
            _ = try? await session.deactivate(options: .notifyOthersOnDeactivation)
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
            throw error
        }
        _ = try await session.deactivate(options: .notifyOthersOnDeactivation)
        try session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
    }
}
#endif
