import CryptoKit
import AVFoundation
import AVFAudio
import AudioDevice
import AudioCore
import AudioMixer
import CallControl
import Codec
import Foundation
import Network
import Observation
import OSLog
import RTC
import SessionManager
import VADGate

@MainActor
@Observable
final class IntercomViewModel {
    let accountSession: AppleAccountSession
    let accountUserID: String?
    let invitationAuthority: DirectInvitationAuthority
    @ObservationIgnored var contactSessionFactory: (() -> CallSession)?
    @ObservationIgnored var contactInvitationSession: ContactInvitationSession?
    var contactInvitationID: UUID?
    var activeInternetContactReplyIDs: Set<UUID> = []
    @ObservationIgnored var suspendedContactInvitation: (id: UUID, access: UUID)?
    @ObservationIgnored var contactInvitationExpiryTask: Task<Void, Never>?
    @ObservationIgnored var beginContactInvitationBackgroundTime: AppBackgroundTime.Request = {
        AppBackgroundTime.begin(name: "Finish Contact Invitation Reply", expiration: $0)
    }
    @ObservationIgnored var endContactInvitationBackgroundTime: (@MainActor () -> Void)?
    @ObservationIgnored var contactNotificationAttemptDuration: Duration = .seconds(60)
    /// How long the person who accepted keeps the exchange open for the two notification permissions.
    @ObservationIgnored var contactPermissionExchangeDuration: Duration = .seconds(10)
    @ObservationIgnored var contactPermissionExchange: (sent: Bool, received: Bool) = (false, false)
    @ObservationIgnored var groupDeliveryClient: InternetAccountClient? =
        SystemSurfaceScope.permitsSystemAccess ? .init() : nil
    @ObservationIgnored var invitationBackgroundTransfer: (any InvitationBackgroundTransferring)?
    @ObservationIgnored var groupDeliveryPathMonitor: NWPathMonitor?
    var networkPathIsAvailable: Bool?
    @ObservationIgnored var groupDeliveryIsForeground = false
    @ObservationIgnored var beginGroupDeliveryBackgroundTime: AppBackgroundTime.Request = {
        AppBackgroundTime.begin(name: "Finish Group Invitation Delivery", expiration: $0)
    }
    @ObservationIgnored var endGroupDeliveryBackgroundTime: (@MainActor () -> Void)?
    @ObservationIgnored var groupDeliveryTask: Task<Bool, Never>?
    @ObservationIgnored var groupDeliverySyncState = GroupDeliverySyncState()
    @ObservationIgnored var allowsNearbyGroupDelivery = SystemSurfaceScope.permitsSystemAccess
    @ObservationIgnored var nearbyGroupDeliveryExchange: NearbyGroupDeliveryExchange?
    @ObservationIgnored var nearbyGroupDeliveryWindow: NearbyGroupDeliveryWindow?
    @ObservationIgnored var nearbyGroupDeliverySchedule = NearbyGroupDeliverySchedule()
    @ObservationIgnored var ordinaryGroupReplyExchanges: [
        OrdinaryGroupReplyExchange.Role: OrdinaryGroupReplyExchange
    ] = [:]
    @ObservationIgnored var ordinaryGroupReplyBackgroundWindow: (id: UUID, end: (@MainActor () -> Void)?)?
    @ObservationIgnored var invitationInternetReplyWindow: InvitationInternetReplyWindow?
    @ObservationIgnored var invitationInternetReplyRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)
    ]
    @ObservationIgnored var beginOrdinaryGroupReplyBackgroundTime: AppBackgroundTime.Request = {
        AppBackgroundTime.begin(name: "Finish Group Invitation Reply", expiration: $0)
    }
    var contactInvitationRevision = UUID()
    var contactInvitationPresentation: ContactInvitationPresentation?
    var contactInvitationMessage: String?
    let accountAccessID: UUID
    var menuBarEnabled = false
    var liveActivityEnabled = false
    var showsGroupsTab = false
    let enforceCallAccess: Bool
    @ObservationIgnored let callAccessNow: @MainActor () -> Date
    @ObservationIgnored let callAccessEvaluation: (@MainActor (Date) -> StoreAccessEvaluation)?
    var callAccessState = CallAccessState()
    @ObservationIgnored var callAccessObservationGeneration = UUID()
    @ObservationIgnored var isRefreshingCallAccess = false
    @ObservationIgnored var lastCallAccessSaveAttempt: TimeInterval?
    let storeAccess: StoreKitAccess
    @ObservationIgnored lazy var notifications = makeCallNotifications()
    var requiresAccountDataReset = false

    var interfaceMode: InterfaceMode = .standard
    var internetWorkerURL = ""
    var internetCredentialState: InternetCredentialState = .missing
    var hasInternetCredentials: Bool { internetCredentialState == .configured }
    var internetCheckMessage = InternetCredentialState.registrationRequiredMessage
    var isCheckingInternet = false
    var internetCheckGeneration = UUID()
    let internetSettingsStore: InternetConnectionSettingsStore
    @ObservationIgnored var automaticInternetEnrollment = AutomaticInternetEnrollment()

    var storedRecentCallDestination: CallDestination?
    var groups: [IntercomGroup]
    var savedUsers: [SavedUser] = []
    var selectedGroup: IntercomGroup?
    var activeGroupID: UUID?
    var callDisconnectInterval: CallDisconnectInterval = .regularDefault
    var watchCallDisconnectInterval: CallDisconnectInterval = .watchDefault
    var callDisconnectDeadline: Date?
    var connectionState: CallConnectionState = .idle
    var isMuted = false
    var isVoiceActive = false
    @ObservationIgnored var localInputObservedAt: TimeInterval?
    var isAudioReady = false
    var isCallMediaStarted = false
    var audioErrorMessage: String?
    var showsCallMicrophonePermissionAlert = false
    var callToPresentAfterPermission: CallReference?
    var callMicrophonePermissionRequest: (id: UUID, task: Task<CallReference?, Never>)?
    var isAudioPausedForDeviceChange = false
    var audioRouteNotice: String?
    var internetTransportFailure: InternetTransportFailure?
    var availableCallRoutes: Set<RTC.RouteKind> = []
    var selectedInputPort: AudioPortInfo = .systemDefault
    var selectedOutputPort: AudioPortInfo = .systemDefault
    var audioSessionProfile = IntercomViewModel.defaultAudioSessionProfile
    var isDuckOthersEnabled = IntercomViewModel.defaultDuckOthersEnabled
    var vadSensitivity = IntercomViewModel.defaultVADSensitivity
    var isSoundIsolationEnabled = IntercomViewModel.defaultSoundIsolationEnabled
    var preferredTransmitCodec: AudioCodecIdentifier = IntercomViewModel.defaultTransmitCodec
    var rtcAudioFormatPreset: RTCAudioFormatPreset = IntercomViewModel.defaultRTCAudioFormatPreset
    var aacELDv2BitRate = IntercomViewModel.defaultAACELDv2BitRate
    var opusBitRate = IntercomViewModel.defaultOpusBitRate
    var enabledRTCTransportRoutes = IntercomViewModel.defaultEnabledRTCTransportRoutes
    var overallOutputVolume: Float = IntercomViewModel.defaultOverallOutputVolume
    var isOutputMuted = false
    var remoteOutputVolumes: [String: Float] = [:]
    var receiveMixSoundIsolationEnabled = IntercomViewModel.defaultReceiveSoundIsolationEnabled
    var remoteSoundIsolationEnabled: [String: Bool] = [:]
    var audioCheckPhase: AudioCheckPhase = .idle
    var audioCheckInputLevel: Float = 0
    var audioCheckInputPeakLevel: Float = 0
    var audioCheckOutputLevel: Float = 0
    var audioCheckOutputPeakLevel: Float = 0
    var audioCheckStatusMessage = "Audio check idle"
    var sentVoicePacketCount = 0
    var receivedVoicePacketCount = 0
    var lastScheduledOutputRMS: Float = 0
    var lastScheduledOutputPeakRMS: Float = 0
    var nativeRenderedOutputBatchCount = 0
    var scheduledOutputBatchCount = 0
    var lastPlaybackScheduledAt: TimeInterval?
    var connectedPeerIDs: [String] = []
    var localAccountPrincipal: AccountPrincipal?
    var authenticatedPeerIDs: [String] = []
    var peerProfiles: [String: PeerProfileState] = [:] {
        didSet { callAccessPeerProfilesChanged(from: oldValue) }
    }
    var localNetworkStatus: LocalNetworkStatus = .idle
    var lastLocalNetworkPeerID: String?
    var lastLocalNetworkEventAt: TimeInterval?
    var lastReceivedAudioAt: TimeInterval?
    var lastAudibleReceivedAudioAt: TimeInterval?
    var droppedAudioPacketCount = 0
    var jitterQueuedFrameCount = 0
    var groupCallIssue: GroupCallIssue?
    var groupStorageIssue: GroupStorageIssue?
    var groupsMissingKeys: Set<UUID> = []
    var groupKeyCleanupPending = false
    var inviteStatusMessage: String?
    let callSession: CallSession
    let audioSessionManager: SessionManager.AudioSessionManager
    let requestMicrophoneAccess: @MainActor () async -> Bool
    let callMicrophonePermission: @MainActor () -> CallMicrophonePermission
    let nativeAudioInputCapture: SessionManager.AudioInputStreamCapture
    let nativeAudioOutputRenderer: SessionManager.AudioOutputStreamRenderer
    #if os(iOS)
    @ObservationIgnored private var audioEngineConfigurationObserver: NSObjectProtocol?
    #endif
    var audioInputCapture: SessionManager.AudioInputStreamCapture
    var audioOutputRenderer: SessionManager.AudioOutputStreamRenderer
    let callTicker: CallTicking
    let groupRepository: GroupRepository
    @ObservationIgnored var callRelationshipSync = CallRelationshipSyncState()
    let appSettingsStore: AppSettingsStoring
    var localMemberIdentity: LocalMemberIdentity
    let localMemberIdentityStore: LocalMemberIdentityStoring
    let remoteTalkerTimeout: TimeInterval
    var inputFrameDelivery: AudioFrameDelivery?
    var isUsingWatchAudio = false
    var watchAudioLink: AudioDeviceConnection?
    let audioPipeline: AppAudioPipeline
    var transmitPacketCounterBaseline = 0
    var audioSessionSnapshot: SessionManager.AudioSessionSnapshot
    var remoteVoiceReceivedAt: [String: TimeInterval] = [:]
    var localVoicePeakWindow = VoicePeakWindow()
    var remoteVoicePeakWindows: [String: VoicePeakWindow] = [:]
    var playbackOutputPeakWindow = VoicePeakWindow()
    var audioCheckInputPeakWindow = VoicePeakWindow()
    var audioCheckOutputPeakWindow = VoicePeakWindow()
    var audioCheckRecordedFrames: [PCMFrame] = []
    var audioCheckRecording: AudioCheckRecording?
    var audioCheckTransmitFailureBaseline = 0
    var audioCheckWatchSessionID: UUID?
    var audioCheckRecordedFrameCount = 0
    var audioCheckRecordedNonzeroSamples = 0
    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
    @ObservationIgnored var audioCheckObservation: AudioCheckValidationObservation?
    @ObservationIgnored var audioCheckObservationRecords: [[String: Any]] = []
    #endif
    var audioCheckGeneration = UUID()
    var connectionGeneration = UUID()
    var audioGeneration = UUID()
    var audioCheckTask: Task<Void, Never>?
    var audioCheckRecordDuration: Duration = .seconds(5)
    var audioCheckPlaybackDuration: Duration = .seconds(5)
    var audioStartTask: Task<Void, Never>?
    var audioCheckOwnsAudioPipeline = false
    var isOtherAudioDuckingActiveInternal = false
    var lastAudioSessionConfigurationReport: SessionManager.AudioSessionConfigurationReport?
    var lastAudioSessionActivationReport: SessionManager.AudioSessionOperationReport?
    var lastInputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastOutputStreamOperationReport: SessionManager.AudioStreamOperationReport?
    var lastVoiceProcessingOperationReport: SessionManager.AudioStreamOperationReport?
    var networkDiagnostics: RTCNetworkDiagnostics?
    var lastRouteMetrics: RTC.RouteMetrics?
    var audioMixerSnapshot: AudioMixerSnapshot = IntercomViewModel.emptyAudioMixerSnapshot()
    var codecRuntimeReport: CodecRuntimeReport = IntercomViewModel.makeCodecRuntimeReport(
        preferredCodec: IntercomViewModel.defaultTransmitCodec,
        aacELDv2BitRate: IntercomViewModel.defaultAACELDv2BitRate,
        opusBitRate: IntercomViewModel.defaultOpusBitRate
    )
    var vadGateRuntimeSnapshot: VADGateRuntimeSnapshot = VADGate(
        configuration: IntercomViewModel.defaultVADSensitivity.configuration
    ).runtimeSnapshot
    var remoteRuntimeStatuses: [String: RTCRuntimeStatus] = [:]
    var lastRuntimePackageReports: [RTCRuntimePackageReport] = []
    var lastRuntimePackageReportPublishedAt: TimeInterval?
    var isDiagnosticsVisible = false

    private init(startup: Startup) {
        self.callAccessEvaluation = startup.callAccessEvaluation
        self.callAccessNow = startup.callAccessNow
        self.invitationAuthority = startup.invitationAuthority
        self.requestMicrophoneAccess = startup.requestMicrophoneAccess
        self.callMicrophonePermission = startup.callMicrophonePermission
        self.accountSession = startup.accountSession
        self.accountUserID = startup.accountUserID
        self.accountAccessID = startup.accountAccessID
        self.storeAccess = startup.storeAccess
        self.enforceCallAccess = startup.enforceCallAccess
        self.groupRepository = startup.groupRepository
        self.groups = startup.groups
        self.callSession = startup.callSession
        self.audioSessionManager = startup.audioSessionManager
        self.nativeAudioOutputRenderer = startup.output
        self.nativeAudioInputCapture = startup.input
        self.audioOutputRenderer = startup.output
        self.audioInputCapture = startup.input
        self.audioPipeline = startup.audioPipeline
        self.callTicker = startup.callTicker
        self.appSettingsStore = startup.appSettingsStore
        self.internetSettingsStore = startup.internetSettingsStore
        self.localMemberIdentity = startup.localMemberIdentity
        self.localMemberIdentityStore = startup.localMemberIdentityStore
        self.audioSessionSnapshot = startup.audioSessionSnapshot
        self.remoteTalkerTimeout = startup.remoteTalkerTimeout

        restoreStartupState(startup)
        bindStartupEvents()
    }

    deinit {
        groupDeliveryPathMonitor?.cancel()
        automaticInternetEnrollment.task?.cancel()
        #if os(iOS)
        if let audioEngineConfigurationObserver {
            NotificationCenter.default.removeObserver(audioEngineConfigurationObserver)
        }
        #endif
    }
}

extension IntercomViewModel {
    convenience init(
        accountSession: AppleAccountSession,
        enforceCallAccess: Bool? = nil,
        callAccessEvaluation: (@MainActor (Date) -> StoreAccessEvaluation)? = nil,
        callAccessNow: @escaping @MainActor () -> Date = Date.init,
        callSession: CallSession? = nil,
        groupRepository: GroupRepository,
        appSettingsStore: AppSettingsStoring,
        internetSettingsStore: InternetConnectionSettingsStore? = nil,
        localMemberIdentityStore: LocalMemberIdentityStoring,
        invitationAuthority: DirectInvitationAuthority,
        requestMicrophoneAccess: @escaping @MainActor () async -> Bool,
        callMicrophonePermission: @escaping @MainActor () -> CallMicrophonePermission = { .granted },
        audioSessionManager: SessionManager.AudioSessionManager? = nil,
        audioInputCapture: SessionManager.AudioInputStreamCapture? = nil,
        audioOutputRenderer: SessionManager.AudioOutputStreamRenderer? = nil,
        audioPipeline: AppAudioPipeline? = nil,
        audioTransmissionController: AudioTransmissionController? = nil,
        callTicker: CallTicking? = nil,
        remoteTalkerTimeout: TimeInterval = 0.6
    ) {
        self.init(startup: Startup(
            accountSession: accountSession,
            enforceCallAccess: enforceCallAccess,
            callAccessEvaluation: callAccessEvaluation,
            callAccessNow: callAccessNow,
            callSession: callSession,
            groupRepository: groupRepository,
            appSettingsStore: appSettingsStore,
            internetSettingsStore: internetSettingsStore,
            localMemberIdentityStore: localMemberIdentityStore,
            invitationAuthority: invitationAuthority,
            requestMicrophoneAccess: requestMicrophoneAccess,
            callMicrophonePermission: callMicrophonePermission,
            audioSessionManager: audioSessionManager,
            audioInputCapture: audioInputCapture,
            audioOutputRenderer: audioOutputRenderer,
            audioPipeline: audioPipeline,
            audioTransmissionController: audioTransmissionController,
            callTicker: callTicker,
            remoteTalkerTimeout: remoteTalkerTimeout
        ))
    }

    private func bindStartupEvents() {
        audioPipeline.applyVADSensitivity(vadSensitivity)
        refreshPackageRuntimeSnapshots()
        callSession.setEnabledRoutes(enabledRTCTransportRoutes)
        callSession.setAudioPolicy(currentCallAudioPolicy())

        refreshGroupStorageStatus()
        bindConnectionEvents()
        audioSessionManager.setRuntimeEventHandler { [weak self] event in
            DispatchQueue.main.async { self?.handleAudioSessionRuntimeEvent(event) }
        }
        #if os(iOS)
        if let engine = nativeAudioOutputRenderer.renderingEngine {
            audioEngineConfigurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // AVAudioEngine delivers this on its internal queue. Leave that queue before rebuilding.
                DispatchQueue.main.async { self?.recoverStoppedNativeCallAudio() }
            }
        }
        #endif
        bindAudioEvents()
        callTicker.onTick = { [weak self] now in
            self?.handleCallTick(now: now)
        }
        accountSession.onAccessRevoked = { [weak self] in self?.endAccountAccess() }
        observeCallAccess()
    }
}
