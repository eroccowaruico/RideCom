import AuthenticationServices
import CryptoKit
import Foundation
import RTC
import Testing

@testable import RideIntercom

@MainActor
@Suite(.serialized)
struct InternetAccountTests {
    func completeOrdinarySignIn(_ account: AppleAccountSession) throws -> (nonce: String, token: Data) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        let nonce = try #require(request.nonce)
        let token = try fixtureIdentityToken()
        try #require(account.completeSignIn(userID: "apple-user", state: request.state, identityToken: token))
        return (nonce, token)
    }

    func completeSavedSignInWithoutProof(_ account: AppleAccountSession) throws {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        try #require(account.completeSignIn(userID: "apple-user", state: request.state))
    }

    func fixtureIdentityToken() throws -> Data {
        let expiresAt = Date().addingTimeInterval(300).timeIntervalSince1970
        let claims = try JSONSerialization.data(withJSONObject: ["exp": expiresAt])
        return Data("fixture.\(IdentityEncoding.encode(claims)).fixture".utf8)
    }

    @Test func throttledPreparationDoesNotResendUntilRetryWindowEnds() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/challenge", retryAfter: "1")
        await authorization.prepare(url: "https://account.test")
        #expect(authorization.message == authorization.retryMessage(seconds: 1))
        #expect(!authorization.isBusy && !authorization.isReady)
        authorization.cancel()
        await authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 1)
        AccountHTTPStub.respond(status: 200)
        try await Task.sleep(for: .milliseconds(1100))
        await authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 2)
        #expect(authorization.isReady)
    }

    @Test(arguments: ["bad", "-5", "0", "999999999999999999999999999", "3601", ""])
    func untrustedRetryDelayIsBounded(value: String) async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/challenge", retryAfter: value)
        await authorization.prepare(url: "https://account.test")
        #expect(authorization.message == authorization.retryMessage(seconds: value == "3601" ? 3600 : 60))
        #expect(!authorization.isReady)
    }

    @Test func exchangeThrottlingKeepsCredentialsUnchangedAndRequiresFreshPreparation() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/session", retryAfter: "60")
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(!authorization.isReady)
        #expect(authorization.message == authorization.retryMessage(seconds: 60))
        await authorization.prepare(url: "https://account.test")
        #expect(AccountHTTPStub.requests.count == 2)
    }

    @Test func deviceCapacityErrorExplainsHowToFreeARegistration() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        AccountHTTPStub.respond(status: 409, path: "/api/auth/apple/session", code: "device_limit_reached")
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(authorization.message?.contains("8 registered devices") == true)
        #expect(authorization.message?.contains("Sign out") == true)
        #expect(!authorization.isReady && !authorization.isBusy)
    }

    @Test(arguments: ["deletion_pending", "unknown"])
    func pendingDeletionAndUnknownConflictAreNotDeviceCapacity(code: String) async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        AccountHTTPStub.respond(status: 409, path: "/api/auth/apple/session", code: code)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil && !authorization.isBusy && !authorization.isReady)
        #expect(authorization.message?.contains("8 registered devices") == false)
        if code == "deletion_pending" {
            #expect(authorization.message?.contains("deletion is still pending") == true)
        }
    }

    @Test func lateThrottleCannotRestoreCancelledStateOrBlockAnotherService() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        AccountHTTPStub.respond(status: 429, path: "/api/auth/apple/session", retryAfter: "60")
        AccountHTTPStub.delayExchange()
        let exchange = Task {
            await authorization.exchange(
                userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        }
        for _ in 0..<100 {
            if AccountHTTPStub.requests.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        authorization.cancel()
        await exchange.value
        #expect(authorization.message == nil)
        AccountHTTPStub.respond(status: 200)
        await authorization.prepare(url: "https://another-account.test")
        #expect(authorization.isReady)
        #expect(fixture.saved == nil)
    }

    @Test func enrollmentUsesServerNonceAndSavesOnlyTheMatchingAccount() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        #expect(request.nonce == String(repeating: "b", count: 64))
        #expect(request.requestedScopes?.isEmpty == true)
        await authorization.exchange(
            userID: "apple-user", state: request.state, identityToken: Data("synthetic-proof".utf8))
        #expect(fixture.saved?.userID == String(repeating: "a", count: 64))
        #expect(fixture.saved?.deviceID == fixture.deviceID)
        #expect(fixture.saved?.accessToken.split(separator: ".")[1] == Substring(String(repeating: "d", count: 64)))
        #expect(authorization.message == "Internet calling is connected to your Apple Account.")
        #expect(
            AccountHTTPStub.requests.map { $0.url?.path } == [
                "/api/auth/apple/challenge", "/api/auth/apple/session", "/api/auth/identity"
            ])
    }

    @Test(arguments: [
        "", "invalid", String(repeating: "d", count: 63), String(repeating: "D", count: 64),
        String(repeating: "d", count: 64) + ".extra"
    ])
    func invalidPrivateLocatorCannotBeSaved(locator: String) async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        AccountHTTPStub.setLocator(locator)
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(authorization.message != "Internet calling is connected to your Apple Account.")
    }

    @Test(arguments: ["sub", "deviceID", "memberID", "deviceKey", "iss", "aud"])
    func mismatchedIdentityCannotBeSavedAndNewCredentialIsRevoked(field: String) async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let wrong: [String: String] = [
            "sub": String(repeating: "b", count: 64), "deviceID": UUID().uuidString.lowercased(),
            "memberID": "another-member",
            "deviceKey": IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation),
            "iss": "https://another.test", "aud": "another-purpose"
        ]
        AccountHTTPStub.changeIdentity([field: try #require(wrong[field])])
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil && fixture.savedIdentity == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
    }

    @Test func differentAccountAndReplayedNativeCompletionNeverExchangeProof() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(
            userID: "another-user", state: request.state, identityToken: Data("proof".utf8))
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(AccountHTTPStub.requests.count == 1)
    }

    @Test func invalidURLAndAccountChangesCannotStartOrFinishEnrollment() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        for url in [
            "http://account.test", "https://user@account.test", "https://account.test/path",
            "https://account.test?secret=x"
        ] {
            await authorization.prepare(url: url)
        }
        #expect(AccountHTTPStub.requests.isEmpty)
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        fixture.currentUser = "changed-user"
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(AccountHTTPStub.requests.count == 1)
    }

    @Test func failedSaveRevokesNewCredentialAndDoesNotReportSuccess() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        fixture.saveFails = true
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        await authorization.exchange(userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        #expect(fixture.saved == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(authorization.message != "Internet calling is connected to your Apple Account.")
    }

    @Test func cancelledExchangeRevokesLateCredentialWithoutSavingIt() async throws {
        let fixture = InternetAccountTestFixture()
        defer { fixture.remove() }
        let authorization = try fixture.makeAuthorization()
        await authorization.prepare(url: "https://account.test")
        AccountHTTPStub.delayExchange()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        authorization.configure(request)
        let exchange = Task {
            await authorization.exchange(
                userID: "apple-user", state: request.state, identityToken: Data("proof".utf8))
        }
        for _ in 0..<100 {
            if AccountHTTPStub.requests.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        authorization.cancel()
        await exchange.value
        #expect(fixture.saved == nil)
        #expect(AccountHTTPStub.requests.last?.httpMethod == "DELETE")
    }
}
