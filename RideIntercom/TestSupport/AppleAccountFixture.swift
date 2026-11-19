#if DEBUG && RIDEINTERCOM_VALIDATION
import AuthenticationServices
import Foundation
import CryptoKit

/// Compiled only into explicitly isolated local validation builds. Ordinary
/// Debug, Release and Archive builds cannot select this provider with an env var.
@MainActor
enum AppleAccountFixture {
    static let userID = "local-validation-apple-user"

    static func makeForCurrentProcess(namespace: String) -> AppleAccountSession? {
        let environment = ProcessInfo.processInfo.environment
        guard namespace.hasPrefix("RideIntercom.Validation."),
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              let mode = environment["RIDEINTERCOM_ACCOUNT_FIXTURE"],
              mode == "signed-in" || mode == "signed-out" else { return nil }
        if let recovery = environment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] {
            do {
                try processGroupRecovery(recovery, namespace: namespace,
                    applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            } catch {
                // This code is absent from normal Debug/Release products. An
                // invalid local fixture must fail the UI launch, not pass silently.
                preconditionFailure("Local saved-group recovery fixture failed: \(error)")
            }
        }
        if mode == "signed-in", let raw = environment["RIDEINTERCOM_CONTACT_NAME_FIXTURE"] {
            do {
                try processContactNameFixture(raw, namespace: namespace,
                    applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            } catch { preconditionFailure("Local contact-name fixture failed: \(error)") }
        }
        if mode == "signed-in", let raw = environment["RIDEINTERCOM_MEMBER_SELECTION_FIXTURE"] {
            do {
                try processContactNameFixture(raw, namespace: namespace,
                    applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0], accountDeviceCount: 8)
            } catch { preconditionFailure("Local member-selection fixture failed: \(error)") }
        }
        if let raw = environment["RIDEINTERCOM_INTERFACE_FIXTURE"], let layout = InterfaceMode(rawValue: raw) {
            let scoped = UserDefaults(suiteName: AppleAccountSession.storageNamespace(base: namespace, userID: userID))!
            scoped.set(layout.rawValue, forKey: "RideIntercom.settings.interfaceMode")
            // UI tests reach groups through the tab; "0" checks the product default (hidden).
            scoped.set(environment["RIDEINTERCOM_GROUPS_TAB"] != "0", forKey: "RideIntercom.settings.showsGroupsTab")
        }
        let defaults = UserDefaults(suiteName: namespace + ".AccountFixture")!
        let session = AppleAccountSession(keychain: FixtureKeychain(defaults: defaults), defaults: defaults,
            namespace: namespace, credentialState: { _ in .authorized })
        if mode == "signed-in" {
            let request = ASAuthorizationAppleIDProvider().createRequest()
            session.prepare(request)
            _ = session.completeSignIn(userID: userID, state: request.state)
            if let seed = environment["RIDEINTERCOM_ACCOUNT_REPLACEMENT_FIXTURE"],
               defaults.string(forKey: "replacementSeed") != seed {
                let scoped = AppleAccountSession.storageNamespace(base: namespace, userID: userID)
                UserDefaults(suiteName: scoped)!.set(true, forKey: "InternetAccount.requiresDataReset")
                defaults.set(seed, forKey: "replacementSeed")
            }
        } else {
            session.signOut()
        }
        return session
    }

    enum RecoveryFailure: Error { case invalidScope, unsafePath, verificationFailed }

    static func groupStore(directory: URL, namespace: String) -> any GroupStoring {
        let store = FileGroupStore(directory: directory)
        let environment = ProcessInfo.processInfo.environment
        guard namespace.hasPrefix("RideIntercom.Validation."),
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              environment["RIDEINTERCOM_FAIL_GROUP_REMOVAL"] == "1" else { return store }
        return GroupRemovalFailureStore(store: store)
    }

    private final class GroupRemovalFailureStore: GroupStoring {
        let store: FileGroupStore

        init(store: FileGroupStore) { self.store = store }
        func read() throws -> GroupSnapshot? { try store.read() }
        func lock() throws { try store.lock() }
        func unlock() { store.unlock() }
        func archive(legacyData: Data?) throws { try store.archive(legacyData: legacyData) }

        func commit(_ snapshot: GroupSnapshot) throws {
            let remainingIDs = Set(snapshot.groups.map(\.id))
            if try store.read()?.groups.contains(where: { !remainingIDs.contains($0.id) }) == true {
                throw GroupStorageError.busy
            }
            try store.commit(snapshot)
        }
    }

    /// Recreates the older outgoing record without a linked SavedUser.
    static func stageLegacyContactInvitationIfRequested(_ viewModel: IntercomViewModel?) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              environment["RIDEINTERCOM_ACCOUNT_FIXTURE"] == "signed-in",
              environment["RIDEINTERCOM_LEGACY_CONTACT_INVITATION_FIXTURE"] == "1",
              let namespace = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String,
              namespace.hasPrefix("RideIntercom.Validation.") else { return }
        guard let viewModel else { preconditionFailure("Local legacy invitation fixture requires a signed-in account") }
        guard viewModel.unlinkedContactInvitations.isEmpty else { return }
        guard viewModel.makeContactInviteURL() != nil else { preconditionFailure("Could not stage local legacy invitation fixture") }
    }

    /// Only the validation account's real group manifest is prepared. No test
    /// state is persisted: the UI test explicitly selects prepare or verify.
    static func processGroupRecovery(_ mode: String, namespace: String, applicationSupport: URL) throws {
        let parts = mode.split(separator: ":")
        guard namespace.range(of: #"^RideIntercom\.Validation\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              parts.count == 2, parts[0] == "prepare" || parts[0] == "verify",
              let fixtureID = UUID(uuidString: String(parts[1])) else { throw RecoveryFailure.invalidScope }
        let corruptGroupBytes = Data("{broken-recovery-fixture:\(fixtureID.uuidString)".utf8)
        let root = applicationSupport.resolvingSymlinksInPath()
        let account = root.appending(path: AppleAccountSession.storageNamespace(base: namespace, userID: userID), directoryHint: .isDirectory)
        let directory = account.appending(path: "Groups", directoryHint: .isDirectory)
        let manifest = directory.appending(path: "groups.json")
        for path in [account, directory, manifest] {
            guard path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else { throw RecoveryFailure.unsafePath }
        }
        if parts[0] == "prepare" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try corruptGroupBytes.write(to: manifest, options: .atomic)
        } else {
            let snapshot = try GroupSnapshot.decode(Data(contentsOf: manifest))
            let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard snapshot.version == GroupSnapshot.currentVersion, snapshot.groups.isEmpty,
                  try archives.contains(where: { path in
                      guard path.lastPathComponent.hasPrefix("groups-corrupt-"), path.pathExtension == "json",
                            path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else { return false }
                      return try Data(contentsOf: path) == corruptGroupBytes
                  }) else { throw RecoveryFailure.verificationFailed }
        }
    }

    /// Seeds a saved, verified-format person for UI interaction only. The native invitation tests
    /// independently exercise receipt delivery; this fixture never replaces that transport evidence.
    static func processContactNameFixture(_ raw: String, namespace: String, applicationSupport: URL, accountDeviceCount: Int = 1) throws {
        guard namespace.range(of: #"^RideIntercom\.Validation\.[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil,
              [1, 8].contains(accountDeviceCount), let id = UUID(uuidString: raw) else { throw RecoveryFailure.invalidScope }
        let root = applicationSupport.resolvingSymlinksInPath()
        let account = root.appending(path: AppleAccountSession.storageNamespace(base: namespace, userID: userID))
        let directory = account.appending(path: "Groups")
        for path in [account, directory, directory.appending(path: "groups.json")] {
            guard path.resolvingSymlinksInPath().standardizedFileURL.path == path.standardizedFileURL.path else { throw RecoveryFailure.unsafePath }
        }
        let store = FileGroupStore(directory: directory)
        try store.lock(); defer { store.unlock() }
        var snapshot = try store.read() ?? GroupSnapshot()
        guard !snapshot.users.contains(where: { $0.id == id }) else { return }
        let suffix = String(id.uuidString.prefix(6)), peer = "name-review-" + id.uuidString
        let peers = accountDeviceCount == 1 ? [peer] : (0..<accountDeviceCount).map { peer + "-\($0)" }
        let keys = Dictionary(uniqueKeysWithValues: peers.map { ($0, IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation)) })
        let accountID = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        snapshot.users.append(SavedUser(id: id, displayName: "Maki " + suffix, memberIDs: peers,
            localName: "A Generated Name " + suffix, deviceKeys: keys,
            principal: accountDeviceCount == 1 ? nil : .init(issuer: "https://account.test", userID: accountID + accountID),
            usesProvisionalName: true))
        snapshot.generation = UUID()
        try store.commit(snapshot)
        guard try store.read() == snapshot else { throw RecoveryFailure.verificationFailed }
    }

    private final class FixtureKeychain: KeychainSecretStoring {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
        private let system = SystemKeychainSecretStore()
        private func isFixtureService(_ service: String) -> Bool {
            service.hasSuffix(".AppleAccount") || service.hasSuffix(".AccountDeletion")
        }
        func accounts(service: String) throws -> [String] {
            if !isFixtureService(service) { return try system.accounts(service: service) }
            return Array((defaults.dictionary(forKey: service) ?? [:]).keys)
        }
        func secret(service: String, account: String) throws -> String? {
            if !isFixtureService(service) { return try system.secret(service: service, account: account) }
            return defaults.dictionary(forKey: service)?[account] as? String
        }
        func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
            if let retained = try secret(service: service, account: account) { return retained }
            try saveSecret(value, service: service, account: account)
            return value
        }
        func saveSecret(_ secret: String, service: String, account: String) throws {
            if !isFixtureService(service) { try system.saveSecret(secret, service: service, account: account); return }
            var values = defaults.dictionary(forKey: service) ?? [:]
            values[account] = secret; defaults.set(values, forKey: service)
        }
        func deleteSecret(service: String, account: String) throws {
            if !isFixtureService(service) { try system.deleteSecret(service: service, account: account); return }
            var values = defaults.dictionary(forKey: service) ?? [:]
            values[account] = nil; defaults.set(values, forKey: service)
        }
    }

    static func makeInternetAuthorization(viewModel: IntercomViewModel) -> InternetAccountAuthorization? {
        let environment = ProcessInfo.processInfo.environment
        guard let namespace = Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String,
              namespace.hasPrefix("RideIntercom.Validation."),
              environment["RIDEINTERCOM_LOCAL_TESTING"] == "1",
              environment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] == "throttled",
              viewModel.accountUserID == userID else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThrottledEnrollment.self]
        return InternetAccountAuthorization(expectedUserID: userID, deviceID: UUID().uuidString.lowercased(),
            memberID: "fixture-member", deviceKey: IdentityEncoding.encode(P256.Signing.PrivateKey().publicKey.x963Representation),
            client: .init(session: URLSession(configuration: configuration)),
            currentUser: { [weak viewModel] in viewModel?.accountSession.userID },
            save: { _, _, _ in throw InternetAccountClient.Failure.rejected })
    }

    // All requests stay in this process; the fixture cannot return a credential.
    private final class ThrottledEnrollment: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "60"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
#endif
