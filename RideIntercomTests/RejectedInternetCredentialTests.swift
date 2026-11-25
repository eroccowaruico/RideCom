import AuthenticationServices
import CallControl
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension InternetAccountTests {
    enum InternetCredentialRenewalOutcome: CaseIterable {
        case updated, oldCertificateExpired, failedToSave, networkInterrupted
    }

    @Test(arguments: InternetCredentialRenewalOutcome.allCases)
    func renewsSavedCredentialWithoutRestartingTheCall(outcome: InternetCredentialRenewalOutcome) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        try completeSavedSignInWithoutProof(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        let configuration = fixture.credential
        let memberID = model.localMemberIdentity.memberID
        let deviceKey = IdentityEncoding.encode(try fixture.signingKey.publicKey.x963Representation)
        let now = floor(Date().timeIntervalSince1970)
        let issuedAt = now - 28 * 86_400
        let expiry = now + (outcome == .oldCertificateExpired ? -60 : 3600)
        let issued = Date(timeIntervalSince1970: issuedAt)
        let certificate = try testIdentityCertificate(
            deviceID: fixture.deviceID, memberID: memberID, deviceKey: deviceKey, now: issued, changes: ["exp": expiry])
        let identity = try certificate.verify(origin: #require(URL(string: "https://account.test")),
                                              trustedIssuerKey: certificate.issuerKey, now: issued)
        try model.saveInternetConnection(url: identity.issuer, token: configuration.accessToken, identity: identity)
        AccountHTTPStub.setSessionExpiry(now + 29 * 86_400)
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        let peer = try #require(group.members.first { $0.id != memberID })
        harness.callSession.authenticate([peer.id], route: .webRTC)
        let call = model.currentCallReference
        let deadline = model.callDisconnectDeadline
        let disconnects = harness.callSession.disconnectCallCount
        #expect(model.setCallMuted(true, for: call))
        #expect(AccountHTTPStub.requests.isEmpty)

        if outcome == .failedToSave { fixture.keychain.failWriteAccount = "current" }
        try await renewCredentialAfterNetworkReturns(model, interrupted: outcome == .networkInterrupted, expiry: expiry)

        let requests = AccountHTTPStub.requests
        let paths = ["session", "identity"]
        let expectedPaths = outcome == .networkInterrupted ? paths + paths : paths
        #expect(requests.map { $0.url?.lastPathComponent } == expectedPaths)
        #expect(requests.first?.httpMethod == (outcome == .oldCertificateExpired ? "GET" : "POST"))
        #expect(try model.internetSettingsStore.load()?.accessToken == configuration.accessToken)
        let expectedExpiry = outcome == .failedToSave ? expiry : now + 29 * 86_400
        #expect(try model.internetSettingsStore.loadIdentity(memberID: memberID)?.expiresAt == expectedExpiry)
        #expect(model.currentCallReference == call && model.isMuted && model.callDisconnectDeadline == deadline)
        #expect(model.authenticatedPeerIDs == [peer.id])
        #expect(harness.callSession.connectCallCount == 1 && harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.callSession.retriedInternetRouteCount == 0)
        model.disconnect()
    }

    private func renewCredentialAfterNetworkReturns(
        _ model: IntercomViewModel, interrupted: Bool, expiry: TimeInterval
    ) async throws {
        if interrupted { AccountHTTPStub.holdResponse(at: "/api/auth/identity") }
        defer { AccountHTTPStub.releaseResponse() }
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let renewal = try #require(model.automaticInternetEnrollment.task)
        if interrupted {
            await AppTestSupport.waitUntil { AccountHTTPStub.hasHeldResponse }
            try #require(AccountHTTPStub.hasHeldResponse)
            model.groupDeliveryNetworkPathChanged(isAvailable: false)
            AccountHTTPStub.releaseResponse()
            await renewal.value
            let memberID = model.localMemberIdentity.memberID
            #expect(try model.internetSettingsStore.loadIdentity(memberID: memberID)?.expiresAt == expiry)
            model.groupDeliveryNetworkPathChanged(isAvailable: true)
            let resumed = try #require(model.automaticInternetEnrollment.task)
            await resumed.value
        } else {
            await renewal.value
        }
    }

    enum IssuedCredentialOutcome: CaseIterable {
        case challengeInFlight, exchangeInFlight, certificateInFlight, signedOut

        var responsePath: String {
            switch self {
            case .challengeInFlight: "/api/auth/apple/challenge"
            case .exchangeInFlight: "/api/auth/apple/session"
            case .certificateInFlight, .signedOut: "/api/auth/identity"
            }
        }
    }

    @Test(arguments: IssuedCredentialOutcome.allCases)
    func enrollmentRespectsTheAppleProofExpiryDuringRegistration(outcome: IssuedCredentialOutcome) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        var now = Date()
        let session = AppleAccountSession(
            keychain: account.keychain, defaults: account.defaults, namespace: account.name,
            enrollmentNow: { now }, credentialState: { _ in .authorized })
        _ = try completeOrdinarySignIn(session)
        let harness = try makeAutomaticEnrollmentHarness(session, fixture: fixture)
        let model = harness.viewModel
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        let proof = try #require(session.enrollmentProof(for: model.accountAccessID))
        let call = model.currentCallReference
        let deadline = try #require(model.callDisconnectDeadline)
        #expect(model.setCallMuted(true, for: call))
        AccountHTTPStub.holdResponse(at: outcome.responsePath)
        defer { AccountHTTPStub.releaseResponse() }
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        await AppTestSupport.waitUntil { AccountHTTPStub.hasHeldResponse }
        try #require(AccountHTTPStub.hasHeldResponse)
        now = proof.expiresAt
        model.reconcileAutomaticInternetEnrollment(executionOpportunity: true)
        #expect(session.enrollmentProof(for: model.accountAccessID) == nil)
        let needsConfirmation = outcome == .challengeInFlight
        #expect(model.callForAppleEnrollmentConfirmation == (needsConfirmation ? call : nil))
        if outcome == .signedOut { session.signOut() }
        AccountHTTPStub.releaseResponse()
        await task.value
        if outcome == .signedOut {
            #expect(!model.hasInternetCredentials && harness.callSession.connectCallCount == 0)
            #expect(model.currentCallReference != call)
            return
        }
        #expect(model.hasInternetCredentials == !needsConfirmation && model.currentCallReference == call)
        #expect(model.isMuted && model.callDisconnectDeadline == deadline)
        #expect(harness.callSession.connectCallCount == (needsConfirmation ? 0 : 1))
        let paths = needsConfirmation ? ["challenge"] : ["challenge", "session", "identity"]
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == paths)
        model.disconnect()
    }

    @Test(arguments: [false, true])
    func rejectedAppleProofWaitsForConfirmationWithinTheSameCall(nearby: Bool) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        if !nearby { model.setRTCTransportRoutes([.webRTC]) }
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        if nearby {
            let peer = try #require(group.members.first { $0.id != model.localMemberIdentity.memberID })
            harness.callSession.authenticate([peer.id])
        }
        let call = model.currentCallReference
        let deadline = try #require(model.callDisconnectDeadline)
        let peers = model.authenticatedPeerIDs
        let disconnects = harness.callSession.disconnectCallCount
        #expect(model.setCallMuted(true, for: call))
        AccountHTTPStub.respond(status: 401, path: "/api/auth/apple/session")
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let rejected = try #require(model.automaticInternetEnrollment.task)
        await rejected.value

        #expect(model.callForAppleEnrollmentConfirmation == call)
        #expect(model.callDisconnectDeadline == deadline && model.isMuted && model.authenticatedPeerIDs == peers)
        #expect(!model.hasInternetCredentials && harness.callSession.connectCallCount == (nearby ? 1 : 0))
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == ["challenge", "session"])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(model.automaticInternetEnrollment.task == nil)

        AccountHTTPStub.respond(status: 200)
        try confirmRejectedCall(model, call: call, endsFirst: false)
        let resumed = try #require(model.automaticInternetEnrollment.task)
        await resumed.value
        #expect(model.hasInternetCredentials && model.currentCallReference == call)
        #expect(model.callDisconnectDeadline == deadline && model.isMuted && model.authenticatedPeerIDs == peers)
        #expect(harness.callSession.connectCallCount == 1 && harness.callSession.disconnectCallCount == disconnects)
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent }
            == ["challenge", "session", "challenge", "session", "identity"])
        model.disconnect()
    }

    enum RejectedCallOutcome: CaseIterable {
        case resumesWithNearby, confirmsForInternetOnly, endsBeforeConfirmation
    }

    @Test(arguments: RejectedCallOutcome.allCases)
    func rejectedCredentialIsReplacedWithinTheSameCall(outcome: RejectedCallOutcome) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        if outcome == .resumesWithNearby {
            _ = try completeOrdinarySignIn(account.session)
        } else {
            try completeSavedSignInWithoutProof(account.session)
        }
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        try model.saveInternetConnection(url: "https://account.test", token: "fixture-old")
        if outcome != .resumesWithNearby { model.setRTCTransportRoutes([.webRTC]) }
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        let call = model.currentCallReference
        #expect(model.setCallMuted(true, for: call))
        if outcome == .resumesWithNearby {
            let peer = try #require(group.members.first { $0.id != model.localMemberIdentity.memberID })
            harness.callSession.authenticate([peer.id])
        }
        let disconnects = harness.callSession.disconnectCallCount
        model.handleTransportEvent(.serviceBlocked(.deviceCredentialRejected))
        if outcome != .resumesWithNearby { model.handleTransportEvent(.linkFailed(willRetry: false)) }
        #expect(!model.hasInternetCredentials && model.currentCallReference == call)
        let reopened = try verifyReopenedStoreStillRejectsCredential(fixture)
        #expect(AccountHTTPStub.requests.isEmpty)

        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        if outcome != .resumesWithNearby {
            try confirmRejectedCall(model, call: call, endsFirst: outcome == .endsBeforeConfirmation)
        }
        if outcome == .endsBeforeConfirmation {
            #expect(model.automaticInternetEnrollment.task == nil && AccountHTTPStub.requests.isEmpty)
            #expect(harness.callSession.retriedInternetRouteCount == 0)
            return
        }
        let task = try #require(model.automaticInternetEnrollment.task)
        await task.value
        #expect(model.hasInternetCredentials && model.currentCallReference == call && model.isMuted)
        #expect(try reopened.load() != nil)
        #expect(model.internetFailureDetail == nil)
        if outcome == .resumesWithNearby { #expect(!model.authenticatedPeerIDs.isEmpty) }
        #expect(harness.callSession.connectCallCount == 1 && harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.callSession.suppliedInternetConfigurationCount == 1)
        #expect(harness.callSession.retriedInternetRouteCount == 1)
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == ["challenge", "session", "identity"])
        model.disconnect()
    }

    @Test func endingDuringRejectedCredentialRegistrationDoesNotResumeCall() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        try model.saveInternetConnection(url: "https://account.test", token: "fixture-old")
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        let call = model.currentCallReference
        AccountHTTPStub.delayExchange()
        model.handleTransportEvent(.serviceBlocked(.deviceCredentialRejected))
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        await AppTestSupport.waitUntil { AccountHTTPStub.requests.contains { $0.url?.lastPathComponent == "session" } }
        try #require(AccountHTTPStub.requests.contains { $0.url?.lastPathComponent == "session" })
        #expect(model.endCall(call))
        await task.value
        #expect(model.hasInternetCredentials)
        #expect(model.currentCallReference != call)
        #expect(harness.callSession.connectCallCount == 1 && harness.callSession.retriedInternetRouteCount == 0)
        #expect(model.automaticInternetEnrollment.waitingCall == nil)
    }

    private func confirmRejectedCall(_ model: IntercomViewModel, call: CallReference, endsFirst: Bool) throws {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let confirmation = try #require(model.prepareCallEnrollmentConfirmation(request, for: call))
        if endsFirst { #expect(model.endCall(call)) }
        model.completeCallEnrollmentConfirmation(confirmation, for: call, userID: "apple-user", state: request.state,
                                                 identityToken: try fixtureIdentityToken())
    }

    private func verifyReopenedStoreStillRejectsCredential(
        _ fixture: InternetAccountTestFixture
    ) throws -> InternetConnectionSettingsStore {
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace,
                                                     fixedWorkerOrigin: URL(string: "https://account.test"))
        #expect(try store.load() == nil)
        #expect(throws: InternetConnectionSettingsStore.ValidationError.missingToken) {
            try store.save(url: "https://account.test", token: "fixture-old")
        }
        return store
    }
}
