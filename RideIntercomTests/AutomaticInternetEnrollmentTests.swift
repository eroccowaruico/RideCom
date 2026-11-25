import AuthenticationServices
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension InternetAccountTests {
    @Test func ordinarySignInRegistersWhenInternetIsEnabledAndAvailable() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        let proof = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentModel(account.session, fixture: fixture)
        model.setRTCTransportRoute(.webRTC, enabled: false)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(AccountHTTPStub.requests.isEmpty)
        #expect(!model.hasInternetCredentials)

        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.setRTCTransportRoute(.webRTC, enabled: true)
        #expect(AccountHTTPStub.requests.isEmpty)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        await task.value

        #expect(model.hasInternetCredentials)
        #expect(try model.internetSettingsStore.load()?.workerURL.absoluteString == "https://account.test")
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == ["challenge", "session", "identity"])
        #expect(account.session.enrollmentProof(for: model.accountAccessID) == nil)
        try verifyEnrollmentSignature(proof)
    }

    @Test func failedRegistrationResumesAfterNetworkRecoveryWithoutEndingANearbyCall() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentModel(account.session, fixture: fixture)
        AccountHTTPStub.respond(status: 503, path: "/api/auth/apple/challenge")
        model.automaticInternetEnrollment.retryDelay = 1
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        await AppTestSupport.waitUntil(timeout: .seconds(2)) { model.automaticInternetEnrollment.retryAt != nil }
        let initial = try #require(model.automaticInternetEnrollment.task)
        #expect(model.automaticInternetEnrollment.retryAt != nil)
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        await initial.value
        #expect(!model.hasInternetCredentials)

        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        AccountHTTPStub.respond(status: 200)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(model.automaticInternetEnrollment.task == nil)
        #expect(AccountHTTPStub.requests.count == 1)
        #expect(model.activeGroupID == group.id)
        model.disconnect()
        let resumed = try #require(model.automaticInternetEnrollment.task)
        await resumed.value
        #expect(model.hasInternetCredentials)
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent }
            == ["challenge", "challenge", "session", "identity"])
    }

    @Test func turningInternetOffDuringRegistrationStopsBeforeCertifying() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentModel(account.session, fixture: fixture)
        AccountHTTPStub.delayExchange()
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let starting = try #require(model.automaticInternetEnrollment.task)
        await AppTestSupport.waitUntil(timeout: .seconds(2)) { AccountHTTPStub.requests.count == 2 }
        try #require(AccountHTTPStub.requests.count == 2)

        model.setRTCTransportRoute(.webRTC, enabled: false)
        await starting.value
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == ["challenge", "session"])
        #expect(!model.hasInternetCredentials)
        #expect(account.session.enrollmentProof(for: model.accountAccessID) != nil)
    }

    private func makeAutomaticEnrollmentModel(_ account: AppleAccountSession, fixture: InternetAccountTestFixture)
        throws -> IntercomViewModel {
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace,
                                                    fixedWorkerOrigin: URL(string: "https://account.test"))
        try fixture.saveDeviceID(fixture.deviceID)
        let model = AppTestSupport.makeHarness(accountSession: account, internetSettingsStore: store).viewModel
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPStub.self]
        AccountHTTPStub.reset(deviceID: fixture.deviceID)
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        model.automaticInternetEnrollment.client = client
        return model
    }

    private func completeOrdinarySignIn(_ account: AppleAccountSession) throws -> (nonce: String, token: Data) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        let nonce = try #require(request.nonce)
        let expiresAt = Date().addingTimeInterval(300).timeIntervalSince1970
        let claims = try JSONSerialization.data(withJSONObject: ["exp": expiresAt])
        let token = Data("fixture.\(IdentityEncoding.encode(claims)).fixture".utf8)
        try #require(account.completeSignIn(userID: "apple-user", state: request.state, identityToken: token))
        return (nonce, token)
    }

    private func verifyEnrollmentSignature(_ proof: (nonce: String, token: Data)) throws {
        let submitted = try #require(AccountHTTPStub.submittedEnrollmentProof)
        let publicKey = try #require(submitted["publicKey"])
        let digest = SHA256.hash(data: Data("ridecom.apple-sign-in-key.v1\n\(publicKey)".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == proof.nonce)
        let key = try P256.Signing.PublicKey(x963Representation: #require(IdentityEncoding.decode(publicKey)))
        let encodedSignature = try #require(submitted["signature"])
        let signatureBytes = try #require(IdentityEncoding.decode(encodedSignature))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        let deviceID = try #require(submitted["deviceID"])
        let tokenDigest = SHA256.hash(data: proof.token).map { String(format: "%02x", $0) }.joined()
        let nonce = String(repeating: "b", count: 64)
        let message = Data("ridecom.apple-enrollment.v1\n\(deviceID)\n\(nonce)\n\(tokenDigest)".utf8)
        #expect(key.isValidSignature(signature, for: message))
    }
}
