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
            let harness = AppTestSupport.makeHarness(enforceCallAccess: false)
            // Microphone permission, activation/control and RTC are fixtures. The shared receive graph,
            // native input, voice processing, failure report and App call path are real.
            let viewModel = IntercomViewModel(
                accountSession: harness.viewModel.accountSession, enforceCallAccess: false,
                callSession: harness.callSession, groupRepository: harness.viewModel.groupRepository,
                appSettingsStore: InMemoryAppSettingsStore(),
                internetSettingsStore: harness.viewModel.internetSettingsStore,
                localMemberIdentityStore: InMemoryLocalMemberIdentityStore(
                    identity: harness.viewModel.localMemberIdentity),
                invitationAuthority: testInvitationAuthority(),
                requestMicrophoneAccess: { true },
                audioSessionManager: SessionManager.AudioSessionManager(backend: harness.audioSessionBackend),
                audioInputCapture: AudioInputStreamCapture(configuration: .intercom(voiceProcessing:
                    IntercomViewModel.defaultVoiceProcessingConfiguration()), engine: engine),
                audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, engine: engine),
                callTicker: NoOpCallTicker())
            defer { viewModel.disconnect(); harness.viewModel.disconnect() }
            viewModel.setInterfaceMode(mode); viewModel.setSoundIsolationEnabled(false)
            viewModel.selectGroup(try #require(viewModel.groups.first))
            await AppTestSupport.waitUntil { viewModel.audioErrorMessage != nil && viewModel.audioStartTask == nil }
            #expect(
                viewModel.lastInputStreamOperationReport?.result
                    == .failed(.invalidFrame("Voice processing requires enabled input hardware")))
            #expect(viewModel.audioErrorMessage == "Microphone capture failed")
            #expect(viewModel.standardCallStatus == .audioUnavailable && viewModel.canDisconnectCall)
            #expect(!viewModel.isAudioReady && !viewModel.isCallMediaStarted && !engine.isRunning)
            #expect(harness.callSession.startMediaCallCount == 0 && viewModel.callDisconnectDeadline != nil)
            viewModel.disconnect()
            #expect(viewModel.callDisconnectDeadline == nil && !viewModel.canDisconnectCall)
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
