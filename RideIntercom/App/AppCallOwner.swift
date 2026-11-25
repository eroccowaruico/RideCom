import AuthenticationServices
import Foundation
import Observation

/// The app and system actions share the same account and call model.
@MainActor @Observable
final class AppCallOwner: CallSurfaceActions {
    let widgetDestinations: WidgetDestinationPublisher
    let liveActivities: CallLiveActivityPresenter
    var systemSurfaceIsForeground = false {
        didSet {
            refreshInvitationDeliveryForegroundState()
            if systemSurfaceIsForeground {
                backupSession?.refreshIfUnavailable()
                viewModel?.callRelationshipBackupSync?.request()
                viewModel?.requestDirectRestoreDeviceSync()
                viewModel?.callRelationshipSync.resumeDirectRestore?()
            }
        }
    }
    let account: AppleAccountSession
    let notificationBridge = AppNotificationBridge()
    var viewModel: IntercomViewModel?
    var callPresentationID: UUID?
    /// Asks the window to show the Users list (a notification whose sender could not be resolved).
    var usersPresentationID: UUID?
    var groupsPresentationID: UUID?
    @ObservationIgnored private let makeViewModel: @MainActor (AppleAccountSession) -> IntercomViewModel?
    @ObservationIgnored private let backupSession: CloudKitCallRelationshipBackupSession?
    @ObservationIgnored private let directRestoreDeviceClient: InternetAccountClient?
    @ObservationIgnored private var credentialRevocationObserver: NSObjectProtocol?
    #if os(iOS)
    let savedCommunicationBackgroundRefresh = SavedCommunicationBackgroundRefresh()
    var watchBridge: WatchPhoneBridge?
    #endif

    init(
        account: AppleAccountSession, viewModel: IntercomViewModel?,
        liveActivityDriver: (any CallLiveActivityDriving)? = nil,
        widgetDestinationStore: WidgetDestinationStore = .system,
        backupSession: CloudKitCallRelationshipBackupSession? = nil,
        directRestoreDeviceClient: InternetAccountClient? = nil,
        makeViewModel: @escaping @MainActor (AppleAccountSession) -> IntercomViewModel? = IntercomViewModel
            .makeForCurrentProcess
    ) {
        widgetDestinations = WidgetDestinationPublisher(store: widgetDestinationStore)
        liveActivities = CallLiveActivityPresenter(driver: liveActivityDriver ?? SystemCallLiveActivityDriver())
        self.makeViewModel = makeViewModel
        self.backupSession = backupSession
        self.directRestoreDeviceClient = directRestoreDeviceClient
        self.account = account
        self.viewModel = viewModel
        credentialRevocationObserver = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.account.revoke() }
        }
        observeAccountAccess()
        observeSystemSurfaces()
        observeWidgetDestinations()
        bindCallRelationshipServices()
    }
    deinit {
        if let credentialRevocationObserver { NotificationCenter.default.removeObserver(credentialRevocationObserver) }
    }

    private func observeAccountAccess() {
        withObservationTracking {
            _ = account.accessID
            _ = account.userID
            _ = account.deletion.blocksSignIn
            _ = account.storageUnavailable
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.synchronizeAccountModel()
                self?.observeAccountAccess()
            }
        }
    }

    private func synchronizeAccountModel() {
        guard viewModel?.accountAccessID != account.accessID || viewModel?.accountUserID != account.userID
                || account.deletion.blocksSignIn else { return }
        #if os(iOS)
        defer { savedCommunicationBackgroundRefresh.accountDidChange() }
        #endif
        backupSession?.bind(to: nil)
        viewModel?.stopCallRelationshipBackup()
        viewModel?.stopDirectRestoreDeviceSync()
        viewModel?.stopGroupDeliverySync()
        viewModel?.notifications.stop()
        viewModel?.stopCallAccessObservation()
        viewModel?.storeAccess.stop()
        viewModel?.disconnect()
        viewModel = nil
        guard !account.storageUnavailable, !account.deletion.blocksSignIn, account.userID != nil else { return }
        viewModel = makeViewModel(account)
        bindCallRelationshipServices()
        refreshInvitationDeliveryForegroundState()
    }

    private func bindCallRelationshipServices() {
        backupSession?.bind(to: viewModel)
        if let directRestoreDeviceClient { viewModel?.startDirectRestoreDeviceSync(using: directRestoreDeviceClient) }
    }

    private func refreshInvitationDeliveryForegroundState() {
        viewModel?.setGroupDeliveryForeground(systemSurfaceIsForeground)
        if systemSurfaceIsForeground { viewModel?.resumeSavedInvitationReplies() }
    }

    func refreshAccountForForeground() async {
        account.reloadSavedSignIn()
        synchronizeAccountModel()
        viewModel?.resumeSuspendedContactInvitation()
        await account.refresh()
        synchronizeAccountModel()
        guard let model = viewModel, model.hasCurrentAccountAccess else { return }
        model.reconcileAutomaticInternetEnrollment()
        async let purchases: Void = model.storeAccess.refresh()
        async let notifications: Void = model.startNotifications()
        _ = await (purchases, notifications)
    }

    var needsSavedCommunicationBackgroundRefresh: Bool {
        viewModel?.needsSavedCommunicationBackgroundRefresh == true
    }

    func refreshSavedCommunicationInBackground() async -> Bool {
        guard !Task.isCancelled else { return false }
        let access = account.accessID
        account.reloadSavedSignIn()
        synchronizeAccountModel()
        guard account.accessID == access, let viewModel, viewModel.hasCurrentAccountAccess else { return false }
        return await viewModel.refreshSavedCommunicationInBackground()
    }

    func prepareForBackgroundCallAction() async throws {
        let previousUserID = account.userID
        let previousAccessID = account.accessID
        account.reloadSavedSignIn()
        if previousUserID != nil, account.userID != previousUserID || account.accessID != previousAccessID {
            throw CallIntentError.unavailable("This sign-in has ended. Open your current account to continue.")
        }
        guard !account.storageUnavailable, !account.deletion.blocksSignIn, !account.isSigningIn,
              let userID = account.userID else {
            throw CallIntentError.unavailable(account.message ?? "Sign in with Apple in RideCom first.")
        }
        let accessID = account.accessID
        synchronizeAccountModel()
        let model = try callModel()
        let reference = model.currentCallReference
        await account.refresh()
        guard !Task.isCancelled, account.userID == userID, account.accessID == accessID,
              !account.storageUnavailable, !account.deletion.blocksSignIn, !account.isSigningIn else {
            throw CallIntentError.unavailable("This sign-in has ended. Open your current account to continue.")
        }
        guard viewModel === model, model.currentCallReference == reference else {
            throw CallIntentError.unavailable(
                "The displayed call has ended or changed. Open RideCom to check your current call.")
        }
        guard model.canStartCalls else {
            throw CallIntentError.unavailable(model.groupStorageNotice ?? "Sign in with Apple in RideCom first.")
        }
        if model.groupStorageIssue == .unavailable, model.activeGroupID == nil { model.reloadSavedGroups() }
    }
}
