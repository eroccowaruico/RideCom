import AVFoundation
import AVFAudio
import Codec
import CryptoKit
import Foundation
import Logging
import Network
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    // AVAudioSession is process-wide; account changes retain its activation ordering.
    private static let processAudioSessionManager = SessionManager.AudioSessionManager()

    static func makeForCurrentProcess(accountSession: AppleAccountSession) -> IntercomViewModel? {
        guard let userID = accountSession.userID else { return nil }
        let base = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String ?? "RideIntercom"
        let namespace = AppleAccountSession.storageNamespace(base: base, userID: userID)
        guard let defaults = UserDefaults(suiteName: namespace) else { return nil }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("Groups", isDirectory: true)
        let localMemberIdentityStore = UserDefaultsLocalMemberIdentityStore(defaults: defaults)
        #if DEBUG && RIDEINTERCOM_VALIDATION
        // UI fixtures start signed in with a name, except the test that checks the name prompt.
        let environment = ProcessInfo.processInfo.environment
        if namespace.hasPrefix("RideIntercom.Validation."), environment["RIDEINTERCOM_ACCOUNT_FIXTURE"] != nil,
           environment["RIDEINTERCOM_NAME_PROMPT"] != "1", !localMemberIdentityStore.loadOrCreate().hasChosenName {
            localMemberIdentityStore.saveDisplayName(localMemberIdentityStore.loadOrCreate().displayName)
        }
        let groupStore = AppleAccountFixture.groupStore(directory: directory, namespace: namespace)
        let callAccessNow = AppleAccountFixture.groupInvitationClock(namespace: namespace)
        #else
        let groupStore = FileGroupStore(directory: directory)
        let callAccessNow: @MainActor () -> Date = Date.init
        #endif
        let groupRepository = GroupRepository(
            store: groupStore, credentials: KeychainGroupCredentialStore(namespace: namespace)
        )
        let model = IntercomViewModel(
            accountSession: accountSession,
            callAccessNow: callAccessNow,
            groupRepository: groupRepository,
            appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults),
            internetSettingsStore: InternetConnectionSettingsStore.makeForCurrentProcess(namespace: namespace),
            localMemberIdentityStore: localMemberIdentityStore,
            invitationAuthority: DirectInvitationAuthority(keychain: SystemKeychainSecretStore(), namespace: namespace),
            requestMicrophoneAccess: {
                let granted = await AVAudioApplication.requestRecordPermission()
                if let denied = MicrophonePermissionLog.denied(AVAudioApplication.shared.recordPermission) {
                    AppLoggers.app.notice("app.permission.microphone.denied", metadata: denied)
                }
                return granted
            },
            audioSessionManager: processAudioSessionManager
        )
        model.monitorGroupDeliveryPath()
        return model
    }

    private func monitorGroupDeliveryPath() {
        guard groupDeliveryClient != nil else { return }
        #if os(iOS)
        invitationBackgroundTransfer = InvitationBackgroundTransfer.shared
        #endif
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.groupDeliveryNetworkPathChanged(isAvailable: path.status == .satisfied)
            }
        }
        groupDeliveryPathMonitor = monitor
        monitor.start(queue: .main)
    }

    static func makeDefaultAudioInputCapture(engine: AVAudioEngine) -> SessionManager.AudioInputStreamCapture {
        SessionManager.AudioInputStreamCapture(
            configuration: .intercom(voiceProcessing: defaultVoiceProcessingConfiguration()), engine: engine
        )
    }

    static func makeDefaultAudioOutputRenderer() -> SessionManager.AudioOutputStreamRenderer {
        SessionManager.AudioOutputStreamRenderer(configuration: .intercom)
    }

    static func defaultVoiceProcessingConfiguration() -> SessionManager.AudioInputVoiceProcessingConfiguration {
        SessionManager.AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            otherAudioDuckingEnabled: defaultDuckOthersEnabled,
            duckingLevel: .minimum,
            inputMuted: false
        )
    }

    static func defaultAudioSessionSnapshot() -> SessionManager.AudioSessionSnapshot {
        SessionManager.AudioSessionSnapshot(
            isActive: false,
            availableInputs: [.systemDefaultInput],
            availableOutputs: [.systemDefaultOutput],
            currentInput: .systemDefaultInput,
            currentOutput: .systemDefaultOutput
        )
    }
}
