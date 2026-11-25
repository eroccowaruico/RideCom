import AuthenticationServices
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension InternetAccountTests {
    @Test(arguments: [false, true])
    func savedCredentialRecoveryRespectsTheOriginalAccountCallDeadline(expired: Bool) throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        try completeSavedSignInWithoutProof(account.session)
        var now = Date()
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture, callAccessNow: { now })
        let model = harness.viewModel
        try model.internetSettingsStore.save(
            url: "https://account.test", token: fixture.credential.accessToken,
            identity: fixture.identity(memberID: model.localMemberIdentity.memberID))
        fixture.keychain.failRead = true
        model.internetCredentialState = .unreadable
        let recipient = accountCallEnrollmentUser("first", accountDigit: "b")
        try model.groupRepository.update(model.groups, credential: nil, users: [recipient])
        model.savedUsers = model.groupRepository.users
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)

        #expect(model.openDestination(.user(recipient.id)) == .opened)
        let deadline = try #require(model.callDisconnectDeadline)
        #expect(model.accountCallWaitingForEnrollment?.id == recipient.id)
        #expect(model.callForAppleEnrollmentConfirmation == nil)
        #expect(harness.callSession.connectCallCount == 0)
        fixture.keychain.failRead = false
        now = expired ? deadline : deadline.addingTimeInterval(-1)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)

        #expect(model.hasInternetCredentials)
        #expect(model.automaticInternetEnrollment.task == nil && AccountHTTPStub.requests.isEmpty)
        #expect(model.accountCallWaitingForEnrollment == nil)
        #expect(harness.callSession.connectCallCount == (expired ? 0 : 1))
        #expect(model.callDisconnectDeadline == (expired ? nil : deadline))
        if !expired {
            let local = try #require(model.localAccountPrincipal)
            #expect(harness.callSession.connectedGroup?.accountPair?.other(than: local) == recipient.principal)
        }
        model.disconnect()
    }

    enum AccountCallEnrollmentResult: CaseIterable {
        case confirmed, automatic, closed, closedWhileRegistering, replaced, removed
    }

    @Test(arguments: AccountCallEnrollmentResult.allCases)
    func accountCallResolvesOnlyThePendingSavedRecipient(result: AccountCallEnrollmentResult) async throws {
        let account = AccountFixture()
        let fixture = InternetAccountTestFixture()
        defer { account.remove(); fixture.remove() }
        if result == .automatic {
            _ = try completeOrdinarySignIn(account.session)
        } else {
            try completeSavedSignInWithoutProof(account.session)
        }
        let harness = try makeAutomaticEnrollmentHarness(account.session, fixture: fixture)
        let model = harness.viewModel
        let first = accountCallEnrollmentUser("first", accountDigit: "b")
        let second = accountCallEnrollmentUser("second", accountDigit: "c")
        try model.groupRepository.update(model.groups, credential: nil, users: [first, second])
        model.savedUsers = model.groupRepository.users
        model.setRTCTransportRoutes([.webRTC])
        model.groupDeliveryNetworkPathChanged(isAvailable: false)
        #expect(model.openDestination(.user(first.id)) == .opened)
        #expect(model.accountCallWaitingForEnrollment?.id == first.id)
        #expect(model.selectedGroup == nil && model.activeGroupID == nil)
        #expect(harness.callSession.connectCallCount == 0 && AccountHTTPStub.requests.isEmpty)
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        if result != .automatic { try confirmAccountCall(model, result: result, original: first, replacement: second) }
        if result == .closedWhileRegistering {
            let task = try #require(model.automaticInternetEnrollment.task)
            model.cancelPendingAccountCallEnrollment()
            await task.value
            #expect(harness.callSession.connectCallCount == 0 && model.activeGroupID == nil)
            #expect(model.accountCallWaitingForEnrollment == nil)
        } else if result == .confirmed || result == .automatic {
            let task = try #require(model.automaticInternetEnrollment.task)
            await task.value
            let local = try #require(model.localAccountPrincipal)
            #expect(model.isActiveCall(.user(first.id)))
            #expect(harness.callSession.connectedGroup?.accountPair?.other(than: local) == first.principal)
            #expect(harness.callSession.connectCallCount == 1)
            #expect(model.accountCallWaitingForEnrollment == nil)
        } else {
            #expect(model.automaticInternetEnrollment.task == nil)
            #expect(harness.callSession.connectCallCount == 0 && AccountHTTPStub.requests.isEmpty)
            #expect(model.accountCallWaitingForEnrollment?.id == (result == .replaced ? second.id : nil))
        }
        model.disconnect()
    }

    private func confirmAccountCall(
        _ model: IntercomViewModel, result: AccountCallEnrollmentResult, original: SavedUser, replacement: SavedUser
    ) throws {
        let reference = model.currentCallReference
        let request = ASAuthorizationAppleIDProvider().createRequest()
        let confirmation = try #require(model.prepareCallEnrollmentConfirmation(request, for: reference))
        switch result {
        case .closed: model.cancelPendingAccountCallEnrollment()
        case .replaced: #expect(model.openDestination(.user(replacement.id)) == .opened)
        case .removed: #expect(model.removeSavedUser(original.id))
        case .confirmed, .automatic, .closedWhileRegistering: break
        }
        model.completeCallEnrollmentConfirmation(
            confirmation, for: reference, userID: "apple-user",
            state: request.state, identityToken: try fixtureIdentityToken())
    }

    private func accountCallEnrollmentUser(_ name: String, accountDigit: String) -> SavedUser {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let id = String(repeating: accountDigit, count: 64)
        let principal = AccountPrincipal(issuer: "https://account.test", userID: id)
        return SavedUser(displayName: name, memberIDs: [name], deviceKeys: [name: IdentityEncoding.encode(key)],
                         principal: principal)
    }
}
