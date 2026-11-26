import AVFAudio
import Foundation
import RTC
import SessionManager

extension IntercomViewModel {
    struct Startup {
        let accountSession: AppleAccountSession
        let accountUserID: String?
        let accountAccessID: UUID
        let storeAccess: StoreKitAccess
        let enforceCallAccess: Bool
        let groupRepository: GroupRepository
        let groups: [IntercomGroup]
        let groupStorageIssue: GroupStorageIssue?
        let callSession: CallSession
        let audioSessionManager: SessionManager.AudioSessionManager
        let input: SessionManager.AudioInputStreamCapture
        let output: SessionManager.AudioOutputStreamRenderer
        let audioPipeline: AppAudioPipeline
        let callTicker: CallTicking
        let appSettings: AppSettings
        let appSettingsStore: AppSettingsStoring
        let internetSettingsStore: InternetConnectionSettingsStore
        let internetConfiguration: Result<RTC.CloudflareRealtimeConfiguration?, any Error>
        let requiresAccountDataReset: Bool
        let localMemberIdentity: LocalMemberIdentity
        let localMemberIdentityStore: LocalMemberIdentityStoring
        let localAccountPrincipal: AccountPrincipal?
        let audioSessionSnapshot: SessionManager.AudioSessionSnapshot
        let invitationAuthority: DirectInvitationAuthority

        let callAccessNow: @MainActor () -> Date
        let callAccessEvaluation: (@MainActor (Date) -> StoreAccessEvaluation)?
        let requestMicrophoneAccess: @MainActor () async -> Bool
        let callMicrophonePermission: @MainActor () -> CallMicrophonePermission
        let remoteTalkerTimeout: TimeInterval

        init(
            accountSession: AppleAccountSession,
            enforceCallAccess: Bool?,
            callAccessEvaluation: (@MainActor (Date) -> StoreAccessEvaluation)?,
            callAccessNow: @escaping @MainActor () -> Date,
            callSession: CallSession?,
            groupRepository: GroupRepository,
            appSettingsStore: AppSettingsStoring,
            internetSettingsStore: InternetConnectionSettingsStore?,
            localMemberIdentityStore: LocalMemberIdentityStoring,
            invitationAuthority: DirectInvitationAuthority,
            requestMicrophoneAccess: @escaping @MainActor () async -> Bool,
            callMicrophonePermission: @escaping @MainActor () -> CallMicrophonePermission,
            audioSessionManager: SessionManager.AudioSessionManager?,
            audioInputCapture: SessionManager.AudioInputStreamCapture?,
            audioOutputRenderer: SessionManager.AudioOutputStreamRenderer?,
            audioPipeline: AppAudioPipeline?,
            audioTransmissionController: AudioTransmissionController?,
            callTicker: CallTicking?,
            remoteTalkerTimeout: TimeInterval
        ) {
            self.accountSession = accountSession
            let userID = accountSession.userID
            let accessID = accountSession.accessID
            accountUserID = userID
            accountAccessID = accessID
            storeAccess = StoreKitAccess(isCurrentUser: {
                !accountSession.deletion.blocksSignIn && userID != nil
                    && accountSession.userID == userID && accountSession.accessID == accessID
            })
            self.enforceCallAccess = enforceCallAccess ?? storeAccess.catalog.isConfigured
            let internetSettingsStore = internetSettingsStore ?? InternetConnectionSettingsStore()
            self.internetSettingsStore = internetSettingsStore
            let identity = localMemberIdentityStore.loadOrCreate()
            localMemberIdentity = identity
            appSettings = appSettingsStore.load()
            self.appSettingsStore = appSettingsStore
            self.groupRepository = groupRepository
            (groups, groupStorageIssue) = IntercomViewModel.restoreGroups(
                in: groupRepository, memberID: identity.memberID
            )
            internetConfiguration = Result { try internetSettingsStore.load() }
            self.callSession = callSession ?? RideIntercomCallSessionAdapter(
                memberID: identity.memberID, internetConfiguration: try? internetConfiguration.get()
            )
            let sessionManager = audioSessionManager ?? SessionManager.AudioSessionManager()
            self.audioSessionManager = sessionManager
            output = audioOutputRenderer ?? IntercomViewModel.makeDefaultAudioOutputRenderer()
            input = audioInputCapture ?? IntercomViewModel.makeDefaultAudioInputCapture(
                engine: output.renderingEngine ?? AVAudioEngine()
            )
            let pipeline = audioPipeline ?? IntercomViewModel.makeCallAudioPipeline(engine: output.renderingEngine)
            pipeline.setTransmissionController(audioTransmissionController ?? AudioTransmissionController())
            self.audioPipeline = pipeline
            self.callTicker = callTicker ?? RepeatingCallTicker()
            requiresAccountDataReset = internetSettingsStore.requiresAccountDataReset
            localAccountPrincipal = try? internetSettingsStore.loadPrincipal(memberID: identity.memberID)
            self.localMemberIdentityStore = localMemberIdentityStore
            audioSessionSnapshot = (try? sessionManager.snapshot()) ?? IntercomViewModel.defaultAudioSessionSnapshot()
            self.invitationAuthority = invitationAuthority
            self.callAccessNow = callAccessNow
            self.callAccessEvaluation = callAccessEvaluation
            self.requestMicrophoneAccess = requestMicrophoneAccess
            self.callMicrophonePermission = callMicrophonePermission
            self.remoteTalkerTimeout = remoteTalkerTimeout
        }
    }

    private static func restoreGroups(
        in repository: GroupRepository, memberID: String
    ) -> (groups: [IntercomGroup], issue: GroupStorageIssue?) {
        do {
            return (try repository.load(localMemberID: memberID), nil)
        } catch {
            return ([], GroupStorageIssue.classify(error))
        }
    }

    private static func makeCallAudioPipeline(engine: AVAudioEngine?) -> AppAudioPipeline {
        if let engine {
            return AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        }
        return AppAudioPipeline()
    }

    func restoreStartupState(_ startup: Startup) {
        let appSettings = startup.appSettings
        self.menuBarEnabled = appSettings.menuBarEnabled
        self.liveActivityEnabled = appSettings.liveActivityEnabled
        self.interfaceMode = appSettings.interfaceMode
        self.showsGroupsTab = appSettings.showsGroupsTab
        if let issue = startup.groupStorageIssue {
            groupStorageIssue = issue
            groupCallIssue = .notice(issue.message)
        }
        requiresAccountDataReset = startup.requiresAccountDataReset
        localAccountPrincipal = startup.localAccountPrincipal
        switch startup.internetConfiguration {
        case .success(let saved?):
            internetWorkerURL = saved.workerURL.absoluteString
            internetCredentialState = .configured
            internetCheckMessage = "Device token configured. Service not checked."
        case .success(nil):
            break
        case .failure:
            internetCredentialState = .unreadable
            internetCheckMessage = "Could not read saved Internet credentials. Saved data has been preserved."
        }
        self.storedRecentCallDestination = appSettings.recentCallDestination
        self.callDisconnectInterval = appSettings.callDisconnectInterval
        self.watchCallDisconnectInterval = appSettings.watchCallDisconnectInterval
        self.audioSessionProfile = appSettings.audioSessionProfile
        self.vadSensitivity = appSettings.vadSensitivity
        self.isSoundIsolationEnabled = appSettings.transmitSoundIsolationEnabled
        self.preferredTransmitCodec = appSettings.preferredTransmitCodec
        self.rtcAudioFormatPreset = appSettings.rtcAudioFormatPreset
        self.aacELDv2BitRate = appSettings.aacELDv2BitRate
        self.opusBitRate = appSettings.opusBitRate
        self.enabledRTCTransportRoutes = appSettings.enabledRTCTransportRoutes
    }
}
