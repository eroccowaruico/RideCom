import AuthenticationServices
import CallControl
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension InternetAccountTests {
    @Test(arguments: [false, true])
    func savedLoginCanVerifyAndResumeTheSameCall(peerIsNearby: Bool) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        if peerIsNearby {
            _ = try completeOrdinarySignIn(account.session)
        } else {
            try completeSavedSignInWithoutProof(account.session)
        }
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        if !peerIsNearby { model.setRTCTransportRoutes([.webRTC]) }
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        let destination = try #require(model.groups.first)
        try #require(model.startCall(to: .group(destination.id), accountAccessID: model.accountAccessID))
        if peerIsNearby {
            let peer = try #require(destination.members.first { $0.id != model.localMemberIdentity.memberID })
            harness.callSession.authenticate([peer.id])
            let proof = try #require(account.session.enrollmentProof(for: model.accountAccessID))
            account.session.discardEnrollmentProof(proof.id)
            model.reconcileAutomaticInternetEnrollment()
        }
        let call = model.currentCallReference
        #expect(model.setCallMuted(true, for: call))
        let request = ASAuthorizationAppleIDProvider().createRequest()
        #expect(model.prepareCallEnrollmentConfirmation(request, for: call) == nil)

        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(model.callForAppleEnrollmentConfirmation == call)
        #expect(AccountHTTPStub.requests.isEmpty)
        let confirmation = try #require(model.prepareCallEnrollmentConfirmation(request, for: call))
        let nonce = try #require(request.nonce)
        let token = try fixtureIdentityToken()
        let disconnects = harness.callSession.disconnectCallCount
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        model.completeCallEnrollmentConfirmation(
            confirmation, for: call, userID: "apple-user", state: request.state, identityToken: token)
        #expect(model.callForAppleEnrollmentConfirmation == nil)
        #expect(AccountHTTPStub.requests.isEmpty)
        #expect(harness.callSession.connectCallCount == (peerIsNearby ? 1 : 0))
        #expect(model.accountAccessID == call.accountAccessID)
        #expect(account.session.userID == "apple-user")

        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        await task.value
        #expect(model.hasInternetCredentials && model.currentCallReference == call && model.isMuted)
        #expect(harness.callSession.connectCallCount == 1)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.callSession.suppliedInternetConfigurationCount == (peerIsNearby ? 1 : 0))
        try verifyEnrollmentSignature((nonce, token), deviceKey: fixture.signingKey.publicKey)
        model.disconnect()
    }

    enum AppleConfirmationChange: CaseIterable { case endCall, internetOff, signOut, wrongAccount, wrongState }

    @Test(arguments: AppleConfirmationChange.allCases)
    func staleOrUnrelatedAppleConfirmationDoesNotRegister(change: AppleConfirmationChange) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        try completeSavedSignInWithoutProof(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let group = try #require(model.groups.first)
        try #require(model.startCall(to: .group(group.id), accountAccessID: model.accountAccessID))
        let call = model.currentCallReference
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let confirmation = try #require(model.prepareCallEnrollmentConfirmation(request, for: call))
        switch change {
        case .endCall: #expect(model.endCall(call))
        case .internetOff: model.setRTCTransportRoutes([.multipeer])
        case .signOut: account.session.signOut()
        case .wrongAccount, .wrongState: break
        }
        model.completeCallEnrollmentConfirmation(
            confirmation, for: call, userID: change == .wrongAccount ? "another-user" : "apple-user",
            state: change == .wrongState ? UUID().uuidString : request.state, identityToken: try fixtureIdentityToken())
        #expect(model.automaticInternetEnrollment.task == nil)
        #expect(AccountHTTPStub.requests.isEmpty)
        #expect(harness.callSession.connectCallCount == 0)
        #expect(account.session.enrollmentProof(for: call.accountAccessID) == nil)
        #expect(account.session.userID == (change == .signOut ? nil : "apple-user"))
        model.disconnect()
    }

    @Test func ordinarySignInRegistersWhenInternetIsEnabledAndAvailable() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        let proof = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture).viewModel
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
        try verifyEnrollmentSignature(proof, deviceKey: fixture.signingKey.publicKey)
    }

    @Test(arguments: [false, true])
    func failedRegistrationResumesAfterNetworkRecoveryWithoutEndingANearbyCall(peerIsPresent: Bool) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        #expect(model.enabledRTCTransportRoutes == [.multipeer, .webRTC])
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
        if peerIsPresent {
            let peer = try #require(group.members.first { $0.id != model.localMemberIdentity.memberID })
            harness.callSession.authenticate([peer.id])
        } else {
            harness.callSession.onEvent?(.connected(peerIDs: []))
        }
        let call = model.currentCallReference
        #expect(model.setCallMuted(true, for: call))
        await AppTestSupport.waitUntil { model.isAudioReady && model.isCallMediaStarted == peerIsPresent }
        try #require(model.isAudioReady && model.isCallMediaStarted == peerIsPresent)
        let disconnects = harness.callSession.disconnectCallCount
        let media = harness.callSession.startMediaCallCount
        let peers = model.authenticatedPeerIDs

        AccountHTTPStub.respond(status: 200)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let resumed = try #require(model.automaticInternetEnrollment.task)
        await resumed.value

        #expect(model.hasInternetCredentials)
        #expect(model.currentCallReference == call && model.isMuted && model.isAudioReady)
        #expect(model.authenticatedPeerIDs == peers && model.isCallMediaStarted == peerIsPresent)
        #expect(harness.callSession.connectCallCount == 1)
        #expect(harness.callSession.suppliedInternetConfigurationCount == 1)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.callSession.startMediaCallCount == media)
        #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent }
            == ["challenge", "challenge", "session", "identity"])
        model.disconnect()
    }

    @Test func turningInternetOffDuringRegistrationStopsBeforeCertifying() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture).viewModel
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

    enum EnrollmentExecution: CaseIterable { case completes, recoversNetwork, returnsToForeground }

    @Test(arguments: EnrollmentExecution.allCases)
    func enrollmentEndsBackgroundTimeAndResumesAfterExpiration(execution: EnrollmentExecution) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let model = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture).viewModel
        var expire: (@MainActor () -> Void)?
        var starts = 0
        var ends = 0
        model.automaticInternetEnrollment.beginBackgroundTime = { expiration in
            starts += 1
            expire = expiration
            return { ends += 1 }
        }
        AccountHTTPStub.delayExchange()
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        #expect(starts == 0)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let initial = try #require(model.automaticInternetEnrollment.task)
        await AppTestSupport.waitUntil(timeout: .seconds(2)) { AccountHTTPStub.requests.count == 2 }
        try #require(AccountHTTPStub.requests.count == 2)
        #expect(starts == 1 && ends == 0)
        if execution != .completes {
            let expiration = try #require(expire)
            expiration()
            #expect(ends == 1)
        }
        await initial.value
        #expect(ends == 1)
        if execution != .completes {
            #expect(!model.hasInternetCredentials)
            #expect(account.session.enrollmentProof(for: model.accountAccessID) != nil)
            #expect(AccountHTTPStub.requests.map { $0.url?.lastPathComponent } == ["challenge", "session"])
            model.groupDeliveryNetworkPathChanged(isAvailable: true)
            #expect(model.automaticInternetEnrollment.task == nil)
            if execution == .recoversNetwork {
                model.groupDeliveryNetworkPathChanged(isAvailable: false)
                model.groupDeliveryNetworkPathChanged(isAvailable: true)
            } else {
                model.reconcileAutomaticInternetEnrollment(executionOpportunity: true)
            }
            let resumed = try #require(model.automaticInternetEnrollment.task)
            await resumed.value
            #expect(starts == 2 && ends == 2)
        }
        #expect(model.hasInternetCredentials)
    }

    @Test func registrationResumesTheSameCallOnceAndPreservesMute() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        let destination = try #require(model.groups.first).id
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        #expect(model.openDestination(.group(destination)) == .opened)
        let call = model.currentCallReference
        #expect(call.groupID == destination && model.standardCallStatus == .connecting && model.canDisconnectCall)
        #expect(model.setCallMuted(true, for: call))
        await AppTestSupport.waitUntil { model.isAudioReady }
        #expect(model.isAudioReady)
        #expect(!model.isCallMediaStarted && harness.callSession.connectCallCount == 0)
        let disconnects = harness.callSession.disconnectCallCount

        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        #expect(model.connectivityNotice == nil)
        await task.value
        model.groupDeliveryNetworkPathChanged(isAvailable: true)

        #expect(model.hasInternetCredentials && model.currentCallReference == call)
        #expect(model.isMuted && model.isAudioReady && model.automaticInternetEnrollment.waitingCall == nil)
        #expect(harness.callSession.connectedGroup?.id == destination && harness.callSession.connectCallCount == 1)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        model.disconnect()
    }

    @Test func rejectedRegistrationEndsTheWaitingCallWithoutSendingMedia() async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        let destination = try #require(model.groups.first).id
        model.setRTCTransportRoutes([.webRTC])
        #expect(model.openDestination(.group(destination)) == .opened)
        AccountHTTPStub.respond(status: 403, path: "/api/auth/apple/challenge")
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        let task = try #require(model.automaticInternetEnrollment.task)
        await task.value

        #expect(model.activeGroupID == nil && model.automaticInternetEnrollment.waitingCall == nil)
        #expect(!model.hasInternetCredentials && !model.isCallMediaStarted && harness.callSession.connectCallCount == 0)
        #expect(model.groupErrorMessage == String(localized: "Could not prepare Internet calling for this device."))
    }

    enum WaitingCallChange: CaseIterable { case end, signOut, revokedRequest, replace }

    @Test(arguments: WaitingCallChange.allCases)
    func registrationDoesNotResumeAnObsoleteCall(change: WaitingCallChange) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        _ = try completeOrdinarySignIn(account.session)
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        let initial = try #require(model.groups.first).id
        let replacement = try #require(model.groups.first { $0.id != initial }).id
        var allowed = true
        model.setRTCTransportRoutes([.webRTC])
        let outcome = model.requestCallStart(to: .group(initial), accountAccessID: model.accountAccessID) { allowed }
        try #require(outcome.startedImmediately)
        switch change {
        case .end: #expect(model.endCall(model.currentCallReference))
        case .signOut: account.session.signOut()
        case .revokedRequest: allowed = false
        case .replace:
            try #require(model.startCall(to: .group(replacement), accountAccessID: model.accountAccessID))
        }

        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        await model.automaticInternetEnrollment.task?.value
        #expect(model.automaticInternetEnrollment.waitingCall == nil)
        #expect(harness.callSession.connectedGroup?.id == (change == .replace ? replacement : nil))
        #expect(harness.callSession.connectCallCount == (change == .replace ? 1 : 0))
        #expect(model.hasInternetCredentials == (change != .signOut))
        model.disconnect()
    }

    func makeAutomaticEnrollmentHarness(
        _ account: AppleAccountSession, fixture: InternetAccountTestFixture,
        callAccessNow: @escaping @MainActor () -> Date = Date.init
    ) throws -> AppTestSupport.Harness {
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: fixture.namespace,
                                                    fixedWorkerOrigin: URL(string: "https://account.test"))
        try fixture.saveDeviceID(fixture.deviceID)
        let harness = AppTestSupport.makeHarness(accountSession: account, internetSettingsStore: store,
                                                 callAccessNow: callAccessNow)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPStub.self]
        AccountHTTPStub.reset(deviceID: fixture.deviceID)
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        harness.viewModel.automaticInternetEnrollment.client = client
        return harness
    }

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

    private func verifyEnrollmentSignature(
        _ proof: (nonce: String, token: Data), deviceKey: P256.Signing.PublicKey
    ) throws {
        let submitted = try #require(AccountHTTPStub.submittedEnrollmentProof)
        let publicKey = try #require(submitted["publicKey"])
        let digest = SHA256.hash(data: Data("ridecom.apple-sign-in-key.v1\n\(publicKey)".utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == proof.nonce)
        let key = try P256.Signing.PublicKey(x963Representation: #require(IdentityEncoding.decode(publicKey)))
        let encodedSignature = try #require(submitted["signature"])
        let signatureBytes = try #require(IdentityEncoding.decode(encodedSignature))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes)
        let deviceID = try #require(submitted["deviceID"])
        let submittedDeviceKey = try #require(submitted["deviceKey"])
        #expect(submittedDeviceKey == IdentityEncoding.encode(deviceKey.x963Representation))
        let tokenDigest = SHA256.hash(data: proof.token).map { String(format: "%02x", $0) }.joined()
        let nonce = String(repeating: "b", count: 64)
        let fields = ["ridecom.apple-enrollment.v1", deviceID, nonce, tokenDigest, submittedDeviceKey]
        let message = Data(fields.joined(separator: "\n").utf8)
        #expect(key.isValidSignature(signature, for: message))
    }
}
