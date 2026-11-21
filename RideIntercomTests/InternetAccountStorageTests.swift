import AuthenticationServices
import CryptoKit
import Foundation
import RTC
import Testing

@testable import RideIntercom

extension InternetAccountTests {
    @Test func verifiedIdentityAndPrivateKeySurviveRestartAndAreDisabledOnSignOut() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        let credential = try #require(fixture.saved)
        let identity = try #require(fixture.savedIdentity)
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try store.save(url: "https://account.test", token: credential.accessToken, identity: identity)
        try fixture.saveDeviceID(credential.deviceID)
        let restarted = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        #expect(try restarted.deletionAccess()?.userID == credential.userID)
        #expect(try restarted.loadIdentity(memberID: "member-fixture")?.userID == credential.userID)
        #expect(try restarted.deviceSigningKey().rawRepresentation == fixture.signingKey.rawRepresentation)
        #expect(throws: (any Error).self) { try restarted.loadIdentity(memberID: "another-member") }
        _ = try restarted.retireAppleCredential()
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.deviceSigningKey().rawRepresentation == fixture.signingKey.rawRepresentation)
    }

    @Test(arguments: [false, true]) func successfulSignOutKeepsDeletionTargetWithoutRestoringInternetAccess(
        archiveWriteFails: Bool
    ) async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        let credential = try #require(fixture.saved)
        let identity = try #require(fixture.savedIdentity)
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try fixture.saveDeviceID(credential.deviceID)
        try store.save(url: "https://account.test", token: credential.accessToken, identity: identity)
        var expected = try #require(try store.deletionAccess())
        expected.requiresAppleVerification = true
        let retired = try #require(try store.retireAppleCredential())
        if archiveWriteFails {
            fixture.keychain.failWrite = true
            #expect(throws: (any Error).self) { try store.finishRevocation(retired) }
            #expect(try store.load() == nil)
            #expect(try store.pendingRevocation() == retired)
            #expect(try store.deletionAccess() == expected)
            fixture.keychain.failWrite = false
        }
        try store.finishRevocation(retired)
        let restarted = InternetConnectionSettingsStore(
            keychain: fixture.keychain, namespace: fixture.namespace,
            developmentDefaults: ["workerURL": "https://fallback.test", "accessToken": "must-not-restore"])
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation() == nil)
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.deletionAccess() == expected)
        #expect(try restarted.identityTrust()?.issuerKey == identity.envelope.issuerKey)
        let isolated = InternetConnectionSettingsStore(
            keychain: fixture.keychain, namespace: fixture.namespace, permitsServiceAccess: false)
        #expect(try isolated.deletionAccess() == nil)
        #expect(try isolated.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try isolated.identityTrust() == nil)
        let other = InternetConnectionSettingsStore(
            keychain: fixture.keychain, namespace: fixture.namespace + ".other")
        #expect(try other.deletionAccess() == nil)
        #expect(try other.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try other.identityTrust() == nil)
        #expect(throws: (any Error).self) { try restarted.loadPrincipal(memberID: "another-device") }
        try fixture.keychain.saveSecret(
            "corrupt", service: fixture.namespace + ".InternetConnection", account: "deletion-account")
        #expect(throws: (any Error).self) { try restarted.deletionAccess() }
        #expect(throws: (any Error).self) { try restarted.loadPrincipal(memberID: "member-fixture") }
        #expect(throws: (any Error).self) { try restarted.identityTrust() }
    }

    @Test(arguments: ["current", "signed-out", "manual"])
    func recreatedAccountKeepsOldDeletionTargetAndCannotRestoreCalls(source: String) throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try fixture.saveDeviceID(fixture.deviceID)
        let oldIdentity = try fixture.identity()
        try store.save(url: "https://account.test", token: fixture.credential.accessToken, identity: oldIdentity)
        let configuration = try #require(try store.load())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        if source == "signed-out" {
            let retired = try #require(try store.retireAppleCredential())
            try store.finishRevocation(retired)
        } else if source == "manual" {
            try store.save(url: "https://account.test", token: "manual-device-token")
            #expect(try store.loadPrincipal(memberID: "member-fixture") == nil)
        }
        let before = fixture.keychain.values
        let replacement = try fixture.identity(userID: String(repeating: "b", count: 64))
        #expect(throws: (any Error).self) {
            try store.save(url: "https://account.test", token: "replacement-device-token", identity: replacement)
        }
        #expect(fixture.keychain.values == before)
        #expect(store.requiresAccountDataReset)
        let restarted = InternetConnectionSettingsStore(
            keychain: fixture.keychain, namespace: fixture.namespace,
            developmentDefaults: ["workerURL": "https://fallback.test", "accessToken": "must-not-restore"])
        #expect(restarted.requiresAccountDataReset)
        expectAccountResetMarkerIsScoped(fixture: fixture)
        #expect(try restarted.load() == nil)
        #expect(try restarted.loadIdentity(memberID: "member-fixture") == nil)
        #expect(try restarted.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try restarted.identityTrust() == nil)
        #expect(try restarted.pendingRevocation() == nil)
        #expect(try restarted.deletionAccess() == target)
        #expect(try restarted.deviceSigningKey().rawRepresentation == fixture.signingKey.rawRepresentation)
        try expectAccountResetToSurviveReadFailure(restarted: restarted, fixture: fixture)
        #expect(throws: (any Error).self) {
            try restarted.save(url: "https://another.test", token: "manual-bypass")
        }
        #expect(throws: (any Error).self) {
            try restarted.save(
                url: "https://account.test", token: fixture.credential.accessToken, identity: oldIdentity)
        }
        #expect(try restarted.retireAppleCredential() == nil)
        try restarted.finishRevocation(configuration)
        #expect(try restarted.deletionAccess() == target)
        #expect(fixture.keychain.values == before)
    }

    @Test func manualSettingsPreserveVerifiedDeletionTargetAndArchiveFailurePreservesCurrent() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try fixture.saveDeviceID(fixture.deviceID)
        try store.save(
            url: "https://account.test", token: fixture.credential.accessToken, identity: fixture.identity())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        let before = fixture.keychain.values
        fixture.keychain.failWriteAccount = "deletion-account"
        #expect(throws: (any Error).self) {
            try store.save(url: "https://account.test", token: "manual-device-token")
        }
        #expect(fixture.keychain.values == before)
        fixture.keychain.failWriteAccount = nil
        try store.save(url: "https://account.test", token: "manual-device-token")
        #expect(try store.load()?.accessToken == "manual-device-token")
        #expect(try store.loadPrincipal(memberID: "member-fixture") == nil)
        #expect(try store.deletionAccess() == target)
        // Repeated manual saves must not replace the last verified registration.
        try store.save(url: "https://account.test", token: "another-manual-token")
        #expect(try store.deletionAccess() == target)
    }

    @Test func signingOutAManualCredentialDoesNotOverwriteTheVerifiedDeletionTarget() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try fixture.saveDeviceID(fixture.deviceID)
        try store.save(
            url: "https://account.test", token: fixture.credential.accessToken, identity: fixture.identity())
        var target = try #require(try store.deletionAccess())
        target.requiresAppleVerification = true
        try store.save(url: "https://account.test", token: fixture.credential.accessToken)
        let pending = try #require(try store.retireAppleCredential())
        try store.finishRevocation(pending)
        #expect(try store.load() == nil)
        #expect(try store.deletionAccess() == target)
    }

    @Test func sameAccountRenewalAndDifferentServiceAreNotAnAccountReplacement() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try store.save(
            url: "https://account.test", token: fixture.credential.accessToken, identity: fixture.identity())
        try store.save(url: "https://account.test", token: "renewed-token", identity: fixture.identity())
        #expect(try store.load()?.accessToken == "renewed-token")
        try store.save(
            url: "https://other.test", token: "different-service-token",
            identity: fixture.identity(userID: String(repeating: "b", count: 64), origin: "https://other.test"))
        #expect(try store.load()?.accessToken == "different-service-token")
        #expect(!store.requiresAccountDataReset)
    }

    @Test func unreadablePreviousRegistrationCannotBeOverwrittenByNewIdentity() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        let identity = try fixture.identity()
        try fixture.keychain.saveSecret(
            "corrupt", service: fixture.namespace + ".InternetConnection", account: "current")
        #expect(throws: (any Error).self) {
            try store.save(url: "https://account.test", token: fixture.credential.accessToken, identity: identity)
        }
        #expect(
            try fixture.keychain.secret(service: fixture.namespace + ".InternetConnection", account: "current")
                == "corrupt")
    }

    @Test func disabledCredentialSurvivesFailedDeletionWithoutBecomingUsable() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        #expect(try store.accountDeviceID() == store.accountDeviceID())
        try store.save(url: "https://account.test", token: fixture.credential.accessToken)
        let retired = try #require(try store.retireAppleCredential())
        #expect(try store.load() == nil)
        fixture.keychain.failDelete = true
        #expect(throws: (any Error).self) { try store.finishRevocation(retired) }
        let restarted = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation()?.accessToken == retired.accessToken)
        fixture.keychain.failDelete = false
        try restarted.finishRevocation(retired)
        #expect(try restarted.pendingRevocation() == nil)
    }

    @Test func oldRevocationCannotDeleteNewlySavedCredential() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try store.save(url: "https://account.test", token: fixture.credential.accessToken)
        let retired = try #require(try store.retireAppleCredential())
        try store.save(url: "https://account.test", token: "new-device-token")
        try store.finishRevocation(retired)
        #expect(try store.load()?.accessToken == "new-device-token")
    }

    @Test func signOutBlocksRestorationEvenWhenKeychainCannotBeRead() throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        try store.save(url: "https://account.test", token: fixture.credential.accessToken)
        fixture.keychain.failRead = true
        #expect(throws: (any Error).self) { try store.retireAppleCredential() }
        fixture.keychain.failRead = false
        let restarted = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace)
        #expect(try restarted.load() == nil)
        #expect(try restarted.pendingRevocation() != nil)
    }

    private func expectAccountResetToSurviveReadFailure(
        restarted: InternetConnectionSettingsStore,
        fixture: InternetAccountTestFixture
    ) throws {
        fixture.keychain.failRead = true
        defer { fixture.keychain.failRead = false }
        #expect(restarted.requiresAccountDataReset)
        #expect(try restarted.load() == nil)
        #expect(throws: (any Error).self) { try restarted.deletionAccess() }
    }

    private func expectAccountResetMarkerIsScoped(fixture: InternetAccountTestFixture) {
                #expect(
            !InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace + ".other")
                .requiresAccountDataReset)
        #expect(
            InternetConnectionSettingsStore(
                keychain: fixture.keychain, namespace: fixture.namespace, permitsServiceAccess: false
            ).requiresAccountDataReset)
    }
}
