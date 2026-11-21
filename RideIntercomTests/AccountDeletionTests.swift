import AuthenticationServices
import CryptoKit
import Foundation
import RTC
import Testing

@testable import RideIntercom

@MainActor
@Suite(.serialized)
struct AccountDeletionTests {
    @Test(arguments: [true, false])
    func newerServerAccountIsPreservedWithoutAdvisingAppleRemoval(withProof: Bool) async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        try session.deletion.begin(
            userID: "owner", access: fixture.access,
            proof: withProof
                ? .init(challengeID: "challenge", identityToken: "token", authorizationCode: "code") : nil)
        await session.resumeDeletion(
            client: fixture.client(body: [
                "deleted": true, "appleAuthorizationRevoked": false, "newerAccountPreserved": true
            ]))
        #expect(session.deletion.canFinish)
        #expect(!session.deletion.requiresManualAppleRemoval)
        #expect(session.deletion.record?.serverResult?.newerAccountPreserved == true)
        if withProof { #expect(DeletionHTTPStub.lastBody["expectedUserID"] == fixture.access.userID) }
    }

    @Test func expiredPendingReceiptRequiresFreshProofAndKeepsLocalErasure() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        try session.deletion.begin(userID: "owner", access: fixture.access, proof: nil)
        let client = fixture.client(body: [
            "deleted": true, "appleAuthorizationRevoked": false, "appleRevocationPending": true
        ])
        await session.resumeDeletion(client: client)
        DeletionHTTPStub.respond(status: 401, body: [:])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(session.deletion.record?.serverResult == nil)
        #expect(!session.deletion.canFinish)
        let proof = InternetAccountDeletionProof(
            challengeID: "fresh", identityToken: "fresh-token", authorizationCode: "fresh-code")
        try session.deletion.replaceProof(proof)
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.canFinish && !session.deletion.requiresManualAppleRemoval)
    }

    @Test(arguments: [false, true])
    func mediaCleanupBlocksCompletionAcrossRestart(applePending: Bool) async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        try session.deletion.begin(userID: "owner", access: fixture.access, proof: nil)
        let client = fixture.client(body: [
            "deleted": true, "appleAuthorizationRevoked": !applePending,
            "appleRevocationPending": applePending, "mediaCleanupPending": true
        ])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(!session.deletion.canFinish)
        #expect(session.deletion.message?.contains("Internet call cleanup") == true)
        #expect(throws: (any Error).self) { try session.deletion.finish() }
        let restarted = try fixture.session()
        #expect(restarted.deletion.blocksSignIn && !restarted.deletion.canFinish)
        DeletionHTTPStub.respond(body: [
            "deleted": true, "appleAuthorizationRevoked": true, "mediaCleanupPending": true
        ])
        await restarted.resumeDeletion(client: client)
        #expect(!restarted.deletion.canFinish)
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await restarted.resumeDeletion(client: client)
        #expect(restarted.deletion.canFinish)
        #expect(DeletionHTTPStub.requests.count == 3)
        try restarted.deletion.finish()
        #expect(try !fixture.session().deletion.blocksSignIn)
    }

    @Test func signedOutAccountRequiresFreshProofBeforeDeletionStarts() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        var access = fixture.access
        access.requiresAppleVerification = true
        #expect(throws: (any Error).self) {
            try session.deletion.begin(userID: "owner", access: access, proof: nil)
        }
        #expect(!session.deletion.blocksSignIn)
        let proof = InternetAccountDeletionProof(
            challengeID: "fresh", identityToken: "token", authorizationCode: "code")
        try session.deletion.begin(userID: "owner", access: access, proof: proof)
        let restarted = try fixture.session()
        #expect(restarted.deletion.record?.access?.requiresAppleVerification == true)
        #expect(throws: (any Error).self) { try restarted.deletion.replaceProof(nil) }
        #expect(restarted.deletion.record?.proof == proof)
    }

    @Test func unauthorizedDeletionDoesNotEraseLocalDataOrDropProof() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        let proof = InternetAccountDeletionProof(
            challengeID: "challenge", identityToken: "token", authorizationCode: "code")
        try session.deletion.begin(userID: "owner", access: fixture.access, proof: proof)
        let client = fixture.client(status: 401)
        await session.resumeDeletion(client: client)
        #expect(!session.deletion.canFinish && session.deletion.record?.localErased == false)
        #expect(session.deletion.record?.proof == proof)
        #expect(session.deletion.record?.serverResult == nil)
        #expect(session.userID == nil)
    }

    @Test func acceptedDeletionErasesLocallyWhileAppleRetrySurvivesRestart() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        try session.deletion.begin(
            userID: "owner", access: fixture.access,
            proof: .init(challengeID: "challenge", identityToken: "token", authorizationCode: "code"))
        let client = fixture.client(body: [
            "deleted": true, "appleAuthorizationRevoked": false, "appleRevocationPending": true
        ])
        await session.resumeDeletion(client: client)
        #expect(session.deletion.record?.localErased == true)
        #expect(session.deletion.record?.proof == nil)
        #expect(!session.deletion.canFinish)
        let restarted = try fixture.session()
        DeletionHTTPStub.respond(body: ["deleted": true, "appleAuthorizationRevoked": true])
        await restarted.resumeDeletion(client: client)
        #expect(restarted.deletion.canFinish && !restarted.deletion.requiresManualAppleRemoval)
        #expect(DeletionHTTPStub.requests.map(\.httpMethod) == ["DELETE", "DELETE"])
        #expect(DeletionHTTPStub.requests.allSatisfy { $0.url?.path == "/api/auth/account" })
        #expect(
            DeletionHTTPStub.requests.last?.httpBody == nil && DeletionHTTPStub.requests.last?.httpBodyStream == nil
        )
        try restarted.deletion.finish()
        #expect(try !fixture.session().deletion.blocksSignIn)
    }

    @Test(arguments: [
        ["deleted": false, "appleAuthorizationRevoked": true],
        ["deleted": true, "appleAuthorizationRevoked": true, "appleRevocationPending": true],
        ["deleted": true],
        ["deleted": true, "appleAuthorizationRevoked": true, "newerAccountPreserved": true],
        [
            "deleted": true, "appleAuthorizationRevoked": false, "newerAccountPreserved": true,
            "mediaCleanupPending": true
        ]
    ])
    func malformedSuccessCannotEraseLocalData(body: [String: Bool]) async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        try session.deletion.begin(userID: "owner", access: fixture.access, proof: nil)
        await session.resumeDeletion(client: fixture.client(body: body))
        #expect(session.deletion.record?.serverResult == nil)
        #expect(session.deletion.record?.localErased == false)
        #expect(!session.deletion.canFinish)
    }

    @Test func freshDeletionProofRequiresSameAppleUserStateAndCurrentAccess() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let client = fixture.client()
        var current = true
        var accepted: InternetAccountDeletionProof?
        let auth = AccountDeletionAuthorization(
            userID: "owner", access: fixture.access, client: client,
            isCurrent: { current }, accept: { accepted = $0 })
        for condition in ["wrongUser", "wrongState", "retired", "valid", "replay"] {
            if condition != "replay" { await auth.prepare() }
            let request = ASAuthorizationAppleIDProvider().createRequest()
            if condition != "replay" { auth.configure(request) }
            #expect(request.requestedScopes?.isEmpty != false)
            if condition == "retired" { current = false }
            auth.submit(
                userID: condition == "wrongUser" ? "other" : "owner",
                state: condition == "wrongState" ? "wrong" : request.state, token: Data("identity".utf8),
                code: Data("code".utf8))
            if condition == "valid" {
                #expect(accepted?.authorizationCode == "code")
                accepted = nil
            } else {
                #expect(accepted == nil)
            }
            current = true
        }
    }
}

// Local erasure, journal recovery and replacement accounts.
extension AccountDeletionTests {
    @Test func failedJournalWriteDoesNotRevokeLogin() throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        fixture.signIn()
        fixture.keychain.fails = true
        #expect(throws: (any Error).self) {
            try fixture.session.deletion.begin(userID: "apple-user", access: nil, proof: nil)
        }
        #expect(!fixture.session.deletion.blocksSignIn && fixture.session.userID == "apple-user")
    }

    @Test func erasedGenerationRejectsRetainedRepositoryWrites() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let store = FileGroupStore(
            directory: fixture.root.appendingPathComponent(fixture.scoped("owner")).appendingPathComponent("Groups")
        )
        let repository = GroupRepository(
            store: store,
            credentials: KeychainGroupCredentialStore(
                keychain: fixture.keychain, namespace: fixture.scoped("owner")))
        _ = try repository.load(localMemberID: "local")
        try fixture.eraser.erase(userID: "owner")
        #expect(throws: GroupStorageError.changedByAnotherProcess) { try repository.save([]) }
    }

    @Test func eraseIsAccountScopedAndInvalidatesOldSnapshotsIncludingCorruptArchives() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let own = fixture.scoped("owner")
        let other = fixture.scoped("other")
        for namespace in [own, other] {
            try #require(UserDefaults(suiteName: namespace)).set(
                "Private name", forKey: "RideIntercom.localDisplayName")
            for suffix in AccountDataEraser.keychainSuffixes {
                try fixture.keychain.saveSecret("secret", service: namespace + suffix, account: "sample")
            }
            let directory = fixture.root.appendingPathComponent(namespace).appendingPathComponent("Groups")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("corrupt private data".utf8).write(to: directory.appendingPathComponent("groups.json"))
            try Data("archive".utf8).write(to: directory.appendingPathComponent("groups-corrupt-backup.json"))
        }
        try fixture.eraser.erase(userID: "owner")
        let store = FileGroupStore(
            directory: fixture.root.appendingPathComponent(own).appendingPathComponent("Groups"))
        let snapshot = try #require(try store.read())
        #expect(snapshot.groups.isEmpty && snapshot.users.isEmpty)
        try fixture.eraser.erase(userID: "owner")
        #expect(try store.read()?.generation != snapshot.generation)
        #expect(try #require(UserDefaults(suiteName: own)).persistentDomain(forName: own)?.isEmpty != false)
        #expect(
            try #require(UserDefaults(suiteName: other)).string(forKey: "RideIntercom.localDisplayName")
                == "Private name")
        for suffix in AccountDataEraser.keychainSuffixes {
            #expect(fixture.keychain.accounts(service: own + suffix).isEmpty)
            #expect(!fixture.keychain.accounts(service: other + suffix).isEmpty)
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path).sorted()
                == ["groups.json", "groups.lock"])
    }

    @Test func eraseCannotBypassARepositoryLockOrFollowAnotherAccountsDirectory() throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent(fixture.scoped("owner"))
        let store = FileGroupStore(directory: directory.appendingPathComponent("Groups"))
        try store.lock()
        #expect(throws: (any Error).self) { try fixture.eraser.erase(userID: "owner") }
        store.unlock()
        try FileManager.default.removeItem(at: directory)
        let other = fixture.root.appendingPathComponent(fixture.scoped("other"))
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: other.appendingPathComponent("private"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: other)
        #expect(throws: (any Error).self) { try fixture.eraser.erase(userID: "owner") }
        #expect(try String(contentsOf: other.appendingPathComponent("private"), encoding: .utf8) == "keep")
    }

    @Test func pendingDeletionSurvivesRestartAndPreservesProofUntilServerAcknowledges() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        let access = AccountDeletion.ServiceAccess(
            workerURL: fixture.serviceURL, accessToken: "ri1.test", deviceID: UUID().uuidString)
        let proof = InternetAccountDeletionProof(
            challengeID: "challenge", identityToken: "token", authorizationCode: "code")
        try session.deletion.begin(userID: "owner", access: access, proof: proof)
        session.signOut()
        let restarted = try fixture.session()
        #expect(restarted.userID == nil && restarted.deletion.blocksSignIn)
        fixture.signIn(restarted)
        #expect(restarted.userID == nil)
        #expect(restarted.deletion.record?.proof == proof)
        #expect(restarted.deletion.record?.access == access)
        #expect(!restarted.deletion.canFinish)
        // An unreadable journal must not be treated as an empty account.
        try fixture.keychain.saveSecret("broken", service: fixture.name + ".AccountDeletion", account: "pending")
        let unreadable = try fixture.session()
        #expect(unreadable.deletion.blocksSignIn && unreadable.userID == nil)
    }

    @Test func replacedAccountCleanupRetriesLocallyAndCreatesFreshKeysAfterRestart() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let namespace = fixture.scoped("owner")
        let store = InternetConnectionSettingsStore(keychain: fixture.keychain, namespace: namespace)
        let oldKey = try store.deviceSigningKey().rawRepresentation
        let oldDeviceID = try store.accountDeviceID()
        // The reset marker is account-scoped, like the normal sign-out marker.
        try #require(UserDefaults(suiteName: namespace)).set(true, forKey: "InternetAccount.requiresDataReset")
        try fixture.keychain.saveSecret(
            "old-invitation-key", service: namespace + ".DirectInvitations", account: "issuer")
        let session = try fixture.session()
        fixture.signIn(session)
        let viewModel = AppTestSupport.makeHarness(accountSession: session, internetSettingsStore: store).viewModel
        #expect(viewModel.hasCurrentAccountAccess && !viewModel.canStartCalls)
        let locked = try lockGroupStoreWithSavedData(namespace: namespace, root: fixture.root)
        try viewModel.beginAccountDataReset()
        #expect(session.userID == nil && session.deletion.isLocalReset)
        #expect(!session.deletion.requiresManualAppleRemoval)
        let client = fixture.client(status: 500)
        await session.resumeDeletion(client: client)
        #expect(!session.deletion.canFinish && store.requiresAccountDataReset)
        #expect(DeletionHTTPStub.requests.isEmpty)
        #expect(session.deletion.message?.contains("No Internet connection is needed") == true)
        locked.unlock()
        let restarted = try fixture.session()
        #expect(restarted.deletion.isLocalReset)
        fixture.keychain.failWriteAccount = "device-id"
        await restarted.resumeDeletion(client: client)
        #expect(!restarted.deletion.canFinish && restarted.deletion.record?.localErased == false)
        #expect(restarted.deletion.record?.retainedDeviceID == oldDeviceID)
        #expect(DeletionHTTPStub.requests.isEmpty)
        fixture.keychain.failWriteAccount = nil
        restarted.deletion.reload()
        await restarted.resumeDeletion(client: client)
        #expect(restarted.deletion.canFinish && !restarted.deletion.requiresManualAppleRemoval)
        #expect(DeletionHTTPStub.requests.isEmpty)
        #expect(!store.requiresAccountDataReset)
        #expect(fixture.keychain.accounts(service: namespace + ".DirectInvitations").isEmpty)
        #expect(try store.deviceSigningKey().rawRepresentation != oldKey)
        // Reuse the registration slot even if best-effort revoke of the new
        // credential failed. All signing and group keys are still replaced.
        #expect(try store.accountDeviceID() == oldDeviceID)
        let erased = try #require(try locked.read())
        #expect(erased.groups.isEmpty && erased.users.isEmpty)
        try restarted.deletion.finish()
        fixture.signIn(restarted)
        let freshHarness = AppTestSupport.makeHarness(
            accountSession: restarted, groups: [], internetSettingsStore: store)
        let fresh = freshHarness.viewModel
        #expect(fresh.canStartCalls && fresh.savedUsers.isEmpty && fresh.groups.isEmpty)
        #expect(!viewModel.canStartCalls)
        #expect(throws: (any Error).self) { try viewModel.beginAccountDataReset() }
        #expect(throws: (any Error).self) { try fresh.beginAccountDataReset() }
    }

    @Test func localDeletionEndsAccessAndCanResumeAfterStorageFailure() async throws {
        let fixture = try DeletionFixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        fixture.signIn(session)
        let harness = AppTestSupport.makeHarness(accountSession: session)
        let viewModel = harness.viewModel
        let directory = fixture.root.appendingPathComponent(fixture.scoped("owner")).appendingPathComponent(
            "Groups")
        let locked = FileGroupStore(directory: directory)
        try locked.lock()
        try session.deletion.begin(userID: "owner", access: nil, proof: nil)
        await session.resumeDeletion()
        #expect(!viewModel.canStartCalls && !viewModel.canEditSavedGroups)
        #expect(session.deletion.blocksSignIn && !session.deletion.canFinish)
        locked.unlock()
        let restarted = try fixture.session()
        await restarted.resumeDeletion()
        #expect(restarted.deletion.canFinish)
        #expect(restarted.deletion.requiresManualAppleRemoval)
        try restarted.deletion.finish()
        #expect(!restarted.deletion.blocksSignIn)
        fixture.signIn(restarted)
        #expect(restarted.userID == "owner")
        #expect(!viewModel.canStartCalls)
    }

    private func lockGroupStoreWithSavedData(namespace: String, root: URL) throws -> FileGroupStore {
        let locked = FileGroupStore(
            directory: root.appendingPathComponent(namespace).appendingPathComponent("Groups"))
        try locked.lock()
        try locked.commit(
            GroupSnapshot(
                groups: IntercomSeedData.recentGroups.map { .init($0) },
                users: [.init(displayName: "Old friend", memberIDs: ["old-friend"])]))
        return locked
    }
}
