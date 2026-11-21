import AuthenticationServices
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct AppleAccountTests {
    #if DEBUG && RIDEINTERCOM_VALIDATION
    @Test func unconfiguredValidationLaunchStaysBlockedAfterRefreshAndRevocation() async {
        let session = AppleAccountFixture.unavailableLaunchSession()
        await session.reload()
        session.revoke()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        session.prepare(request)

        #expect(session.launchInstructions != nil)
        #expect(session.storageUnavailable)
        #expect(session.userID == nil)
        #expect(!session.isSigningIn)
    }
    #endif

    @Test func allRoutesRequireLoginAndSignOutStopsActiveCall() async throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        let denied = AppTestSupport.makeHarness(accountSession: fixture.session)
        denied.viewModel.selectGroup(try #require(denied.viewModel.groups.first))
        #expect(denied.callSession.connectedGroup == nil)
        denied.viewModel.startAudioPipelineIfNeeded()
        #expect(!denied.viewModel.isAudioReady)
        fixture.signIn()
        let allowed = AppTestSupport.makeHarness(accountSession: fixture.session)
        defer { allowed.viewModel.disconnect() }
        // This verifies authorization and media shutdown; native ML effect
        // initialization is exercised by the dedicated audio tests.
        allowed.viewModel.setSoundIsolationEnabled(false)
        allowed.viewModel.selectGroup(try #require(allowed.viewModel.groups.first))
        #expect(allowed.callSession.connectedGroup != nil)
        allowed.callSession.authenticate(try #require(allowed.viewModel.selectedGroup).members.dropFirst().map(\.id))
        await AppTestSupport.waitUntil { allowed.viewModel.isAudioReady }
        #expect(allowed.viewModel.isAudioReady)
        let savedGroups = allowed.viewModel.groups
        fixture.session.signOut()
        #expect(allowed.viewModel.activeGroupID == nil)
        #expect(!allowed.viewModel.isAudioReady)
        #expect(allowed.viewModel.groups.map(\.id) == savedGroups.map(\.id))
        let count = allowed.callSession.startMediaCallCount
        allowed.viewModel.connectLocal()
        #expect(allowed.callSession.connectedGroup == nil && allowed.callSession.startMediaCallCount == count)
        fixture.signIn("other-account")
        allowed.viewModel.connectLocal()
        #expect(allowed.callSession.connectedGroup == nil && allowed.callSession.startMediaCallCount == count)
    }
    @Test(arguments: ["apple-user", "other-account"])
    func retiredModelCannotRegainAccessAfterAnotherLogin(nextUser: String) throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        let old = AppTestSupport.makeHarness(accountSession: fixture.session)
        defer { old.viewModel.disconnect() }
        let group = try #require(old.viewModel.groups.first)
        old.viewModel.selectGroup(group)
        fixture.session.signOut()
        fixture.signIn(nextUser)
        #expect(!old.viewModel.canStartCalls)
        #expect(!old.viewModel.canEditSavedGroups)
        #expect(!old.viewModel.canStartAudioCheck)
        old.viewModel.connectLocal()
        #expect(old.callSession.connectedGroup == nil)
        #expect(old.viewModel.makeSelectedGroupInviteURL() == nil)
        #expect(!old.viewModel.setLocalDisplayName("Stale name"))
        let fresh = AppTestSupport.makeHarness(accountSession: fixture.session)
        defer { fresh.viewModel.disconnect() }
        #expect(fresh.viewModel.canStartCalls)
        #expect(fresh.viewModel.canEditSavedGroups)
    }

    @Test func signedOutOperationsCannotChangeSavedDataOrCredentials() throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        let settings = InMemoryAppSettingsStore()
        let internet = InternetConnectionSettingsStore(keychain: InternetTestKeychain(), namespace: "retired-model")
        let harness = AppTestSupport.makeHarness(
            accountSession: fixture.session,
            appSettingsStore: settings,
            internetSettingsStore: internet
        )
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        viewModel.selectGroup(group)
        let invite = try #require(viewModel.makeSelectedGroupInviteURL())
        let before = harness.groupStore.snapshot
        let previousSettings = settings.load()
        fixture.session.signOut()
        #expect(!viewModel.createTalkGroup(name: "Stale operation"))
        #expect(!viewModel.commitGroups([]))
        viewModel.deleteGroup(group.id)
        viewModel.resetSavedGroups()
        #expect(throws: (any Error).self) { try viewModel.acceptInviteURL(invite) }
        #expect(throws: (any Error).self) { try viewModel.credential(for: group) }
        #expect(throws: (any Error).self) {
            try viewModel.saveInternetConnection(url: "https://account.test", token: "stale-token")
        }
        viewModel.setOpusBitRate(16_000)
        #expect(harness.groupStore.snapshot == before)
        #expect(settings.load() == previousSettings)
        #expect(try internet.load() == nil)
    }

    @Test func accountReplacementRevokesOldAccessBeforeShutdownCallback() {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: fixture.session)
        var accessDuringShutdown: Bool?
        fixture.session.onAccessRevoked = { accessDuringShutdown = harness.viewModel.canStartCalls }
        fixture.signIn("other-account")
        #expect(accessDuringShutdown == false)
        fixture.signIn()
        #expect(!harness.viewModel.canStartCalls)
    }
}

extension AppleAccountTests {
    @Test func loginRequiresMatchingRequestAndPersistsOnlyIdentifier() throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        #expect(fixture.session.userID == nil)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        fixture.session.prepare(request)
        #expect(request.requestedScopes?.isEmpty == true)
        #expect(request.state != nil)
        #expect(!fixture.session.completeSignIn(userID: "apple-user", state: "wrong"))
        #expect(fixture.keychain.value == nil)
        fixture.session.prepare(request)
        #expect(fixture.session.completeSignIn(userID: "apple-user", state: request.state))
        #expect(fixture.session.userID == "apple-user")
        #expect(fixture.keychain.value == "apple-user")
        #expect(!fixture.session.completeSignIn(userID: "other-user", state: request.state))
        #expect(fixture.session.userID == "apple-user")
    }

    @Test func restoreAndTemporaryFailureRetainCachedLogin() async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        let restored = fixture.restart { _ in .authorized }
        #expect(restored.userID == "apple-user") // Local calls never wait for an online refresh.
        await restored.refresh()
        #expect(restored.userID == "apple-user")
        let offline = fixture.restart { _ in throw URLError(.notConnectedToInternet) }
        await offline.refresh()
        #expect(offline.userID == "apple-user")
        #expect(offline.message != nil)
    }

    @Test(arguments: [AppleCredentialState.revoked, .notFound, .transferred])
    func invalidCredentialStopsAccessAndDoesNotReturnAfterRestart(state: AppleCredentialState) async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        let restored = fixture.restart { _ in state }
        var stopped = false
        restored.onAccessRevoked = { stopped = true }
        await restored.refresh()
        #expect(restored.userID == nil)
        #expect(stopped)
        #expect(fixture.keychain.value == nil)
        let again = fixture.restart { _ in throw URLError(.notConnectedToInternet) }
        await again.refresh()
        #expect(again.userID == nil)
    }

    @Test func failedKeychainWriteNeverSignsIn() {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.keychain.fails = true
        fixture.signIn()
        #expect(fixture.session.userID == nil)
        #expect(fixture.session.message != nil)
    }

    @Test func cancelledNativeLoginCanBeRetried() {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        fixture.session.prepare(request)
        fixture.session.complete(.failure(ASAuthorizationError(.canceled)))
        #expect(fixture.session.userID == nil)
        #expect(fixture.session.message == nil)
        #expect(!fixture.session.isSigningIn)
        #expect(!fixture.session.completeSignIn(userID: "apple-user", state: request.state))
        fixture.signIn()
        #expect(fixture.session.userID == "apple-user")
    }

    @Test func failedSignOutDeletionCanBeRetriedWithoutSigningIn() async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        fixture.keychain.fails = true
        fixture.session.signOut()
        #expect(fixture.session.storageUnavailable)
        fixture.keychain.fails = false
        await fixture.session.reload()
        #expect(fixture.keychain.value == nil)
        #expect(fixture.session.userID == nil)
        #expect(!fixture.session.storageUnavailable)
    }

    @Test func signOutFailureStillBlocksOfflineRestoration() async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        fixture.keychain.fails = true
        fixture.session.signOut()
        #expect(fixture.session.userID == nil)
        #expect(fixture.session.message != nil)
        fixture.keychain.fails = false
        #expect(fixture.keychain.value != nil) // Failed deletion preserves the original.
        let restored = fixture.restart { _ in throw URLError(.notConnectedToInternet) }
        await restored.refresh()
        #expect(restored.userID == nil)
    }

    @Test func unreadableKeychainIsPreservedAndNotOverwritten() {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        fixture.keychain.fails = true
        let restored = fixture.restart { _ in .authorized }
        fixture.keychain.fails = false
        let request = ASAuthorizationAppleIDProvider().createRequest()
        restored.prepare(request)
        #expect(!restored.completeSignIn(userID: "other", state: request.state))
        #expect(fixture.keychain.value == "apple-user")
        #expect(restored.userID == nil)
    }

    @Test func pendingRefreshCannotUndoSignOut() async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        var continuation: CheckedContinuation<AppleCredentialState, Never>?
        let restored = fixture.restart { _ in await withCheckedContinuation { continuation = $0 } }
        let task = Task { await restored.refresh() }
        await AppTestSupport.waitUntil { continuation != nil }
        restored.signOut()
        continuation?.resume(returning: .authorized)
        await task.value
        #expect(restored.userID == nil)
    }

    @Test func keychainRecoveryPublishesANewAccessForTheSignedInScreen() async {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        fixture.keychain.fails = true
        let recovered = fixture.restart { _ in .authorized }
        let unavailableAccess = recovered.accessID
        #expect(recovered.userID == nil && recovered.storageUnavailable)
        fixture.keychain.fails = false
        await recovered.reload()
        #expect(recovered.userID == "apple-user")
        #expect(recovered.accessID != unavailableAccess)
        let validAccess = recovered.accessID
        await recovered.refresh()
        await recovered.reload()
        #expect(recovered.accessID == validAccess) // Refresh must not replace a live call owner.
    }

    @Test func accountNamespaceIsStableAndIsolated() {
        #expect(
            AppleAccountSession.storageNamespace(base: "Test", userID: "one")
                == AppleAccountSession.storageNamespace(base: "Test", userID: "one")
        )
        #expect(
            AppleAccountSession.storageNamespace(base: "Test", userID: "one")
                != AppleAccountSession.storageNamespace(base: "Test", userID: "two")
        )
        #expect(
            !AppleAccountSession.storageNamespace(base: "Test", userID: "private-apple-id").contains("private-apple-id")
        )
    }
}

@MainActor
final class AccountFixture {
    let keychain = AccountTestKeychain()
    let name = "RideIntercom.AccountTests." + UUID().uuidString
    let defaults: UserDefaults
    lazy var session = restart { _ in .authorized }
    init() {
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Could not open isolated account test defaults")
        }
        self.defaults = defaults
    }
    func remove() { defaults.removePersistentDomain(forName: name) }
    func restart(_ check: @escaping @MainActor (String) async throws -> AppleCredentialState) -> AppleAccountSession {
        AppleAccountSession(keychain: keychain, defaults: defaults, namespace: name, credentialState: check)
    }
    func signIn(_ userID: String = "apple-user") {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        session.prepare(request)
        _ = session.completeSignIn(userID: userID, state: request.state)
    }
}

final class AccountTestKeychain: KeychainSecretStoring {
    var value: String?
    var fails = false
    private var additional: [String: [String: String]] = [:]
    func accounts(service: String) throws -> [String] { [] }
    func secret(service: String, account: String) throws -> String? {
        if fails { throw KeychainSecretStoreError.invalidData }
        return service.hasSuffix(".AccountDeletion") ? additional[service]?[account] : value
    }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws {
        if fails { throw KeychainSecretStoreError.invalidData }
        if service.hasSuffix(".AccountDeletion") {
            additional[service, default: [:]][account] = secret
        } else {
            value = secret
        }
    }
    func deleteSecret(service: String, account: String) throws {
        if fails { throw KeychainSecretStoreError.invalidData }
        if service.hasSuffix(".AccountDeletion") {
            additional[service]?[account] = nil
        } else {
            value = nil
        }
    }
}
