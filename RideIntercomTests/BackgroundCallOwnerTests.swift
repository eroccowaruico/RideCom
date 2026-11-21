import AuthenticationServices
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct BackgroundCallOwnerTests {
    @Test func signedOutAccountRecoversFromUnavailableStorageWithoutLosingSignInEntry() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn(); fixture.session.signOut()
        fixture.keychain.fails = true
        let account = fixture.restart { _ in .authorized }
        #expect(account.storageUnavailable && account.userID == nil)
        fixture.keychain.fails = false
        await account.reload()
        #expect(!account.storageUnavailable && account.userID == nil)
        let request = ASAuthorizationAppleIDProvider().createRequest(); account.prepare(request)
        #expect(account.isSigningIn)
        #expect(account.completeSignIn(userID: "apple-user", state: request.state))
    }

    @Test func endingCallDuringBackgroundPreparationDoesNotAllowDelayedStart() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = fixture.restart { _ in await withCheckedContinuation { pending = $0 } }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let viewModel = harness.viewModel
        let owner = AppCallOwner(account: account, viewModel: viewModel)
        let group = try #require(viewModel.groups.first)
        #expect(viewModel.startCall(to: .group(group.id), accountAccessID: account.accessID))
        let reference = viewModel.currentCallReference
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        #expect(viewModel.endCall(reference))
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(viewModel.activeGroupID == nil)
    }

    @Test func ownerReplacesRetiredModelWithoutAViewAndDoesNotReconnect() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let first = AppTestSupport.makeHarness(accountSession: fixture.session)
        var made = 0
        let owner = AppCallOwner(account: fixture.session, viewModel: first.viewModel, makeViewModel: { account in
            made += 1
            return AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        first.viewModel.selectGroup(try #require(first.viewModel.groups.first))
        fixture.session.signOut()
        #expect(first.viewModel.activeGroupID == nil)
        fixture.signIn("replacement")
        await AppTestSupport.waitUntil { owner.viewModel?.accountUserID == "replacement" }
        #expect(made == 1)
        #expect(owner.viewModel !== first.viewModel)
        #expect(owner.viewModel?.activeGroupID == nil)
        #expect(!first.viewModel.canStartCalls)
    }

    @Test func unavailableSavedLoginDoesNotCreateModelOrOverwriteAndRecoversOnRetry() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        fixture.keychain.fails = true
        let account = fixture.restart { _ in .authorized }
        var made = 0
        let owner = AppCallOwner(account: account, viewModel: nil, makeViewModel: { account in
            made += 1; return AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(made == 0 && fixture.keychain.value == "apple-user")
        fixture.keychain.fails = false
        try await owner.prepareForBackgroundCallAction()
        #expect(made == 1 && owner.viewModel?.canStartCalls == true)
        let model = owner.viewModel
        try await owner.prepareForBackgroundCallAction()
        #expect(owner.viewModel === model && made == 1)
    }

    @Test(arguments: ["apple-user", "another-user"])
    func refreshCannotPassOldActionToANewLogin(nextUser: String) async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = fixture.restart { _ in await withCheckedContinuation { pending = $0 } }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: harness.viewModel, makeViewModel: { account in
            AppTestSupport.makeHarness(accountSession: account).viewModel
        })
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        account.signOut()
        let request = ASAuthorizationAppleIDProvider().createRequest(); account.prepare(request)
        #expect(account.completeSignIn(userID: nextUser, state: request.state))
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(harness.viewModel.activeGroupID == nil)
    }

    @Test func concurrentPreparationWaitsForTheSameCredentialCheck() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        var checks = 0
        let account = fixture.restart { _ in checks += 1; return await withCheckedContinuation { pending = $0 } }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: harness.viewModel)
        let first = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        var secondFinished = false
        let second = Task { defer { secondFinished = true }; try await owner.prepareForBackgroundCallAction() }
        for _ in 0..<10 { await Task.yield() }
        #expect(!secondFinished && checks == 1)
        pending?.resume(returning: .revoked)
        await #expect(throws: CallIntentError.self) { try await first.value }
        await #expect(throws: CallIntentError.self) { try await second.value }
        #expect(account.userID == nil && harness.viewModel.activeGroupID == nil)
    }

    @Test func anotherSessionSignOutInvalidatesCachedAccessBeforeBackgroundPreparation() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let account = fixture.restart { _ in .authorized }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: harness.viewModel)
        harness.viewModel.selectGroup(try #require(harness.viewModel.groups.first))
        let oldAccess = account.accessID
        fixture.session.signOut()
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(account.userID == nil && account.accessID != oldAccess)
        #expect(harness.viewModel.activeGroupID == nil && !harness.viewModel.canStartCalls)
        await account.reload()
        #expect(account.userID == nil)
    }

    @Test func anotherSessionPendingDeletionBlocksBackgroundPreparation() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let account = fixture.restart { _ in .authorized }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: harness.viewModel)
        try fixture.session.deletion.begin(userID: "apple-user", access: nil, proof: nil)
        await #expect(throws: CallIntentError.self) { try await owner.prepareForBackgroundCallAction() }
        #expect(account.userID == nil && account.deletion.blocksSignIn)
        #expect(!harness.viewModel.canStartCalls)
    }

    @Test(arguments: [false, true])
    func persistedDenialDuringNativeCheckCannotBeUndone(deleting: Bool) async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        var pending: CheckedContinuation<AppleCredentialState, Never>?
        let account = fixture.restart { _ in await withCheckedContinuation { pending = $0 } }
        let harness = AppTestSupport.makeHarness(accountSession: account)
        let owner = AppCallOwner(account: account, viewModel: harness.viewModel)
        let preparation = Task { try await owner.prepareForBackgroundCallAction() }
        await AppTestSupport.waitUntil { pending != nil }
        if deleting {
            try fixture.session.deletion.begin(userID: "apple-user", access: nil, proof: nil)
        } else {
            fixture.session.signOut()
        }
        pending?.resume(returning: .authorized)
        await #expect(throws: CallIntentError.self) { try await preparation.value }
        #expect(account.userID == nil && !harness.viewModel.canStartCalls)
    }

    @Test func transientGroupReadFailureRetriesWithoutResettingTheSnapshot() async throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        let saved = harness.groupStore.snapshot
        viewModel.groupStorageIssue = .unavailable
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        try await owner.prepareForBackgroundCallAction()
        #expect(viewModel.groupStorageIssue == nil && harness.groupStore.snapshot == saved)
        #expect(!owner.callTargets.isEmpty)
    }
}
