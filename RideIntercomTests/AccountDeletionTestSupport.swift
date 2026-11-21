import AuthenticationServices
import Foundation
import Testing

@testable import RideIntercom

@MainActor
final class DeletionFixture {
    let name = "RideIntercom.DeletionTests." + UUID().uuidString
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let keychain = DictionaryKeychain()
    let serviceURL: URL

    init() throws {
        serviceURL = try #require(URL(string: "https://deletion.test"))
    }

    var access: AccountDeletion.ServiceAccess {
        .init(
            workerURL: serviceURL, accessToken: "ri1.fixture", deviceID: "11111111-1111-1111-1111-111111111111",
            userID: String(repeating: "a", count: 64))
    }
    func client(
        status: Int = 200,
        body: [String: Bool] = ["deleted": true, "appleAuthorizationRevoked": true]
    ) -> InternetAccountClient {
        DeletionHTTPStub.reset(status: status, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeletionHTTPStub.self]
        return .init(session: URLSession(configuration: config))
    }
    var eraser: AccountDataEraser { .init(keychain: keychain, namespace: name, applicationSupport: root) }
    func scoped(_ user: String) -> String { AppleAccountSession.storageNamespace(base: name, userID: user) }
    func session() throws -> AppleAccountSession {
        try AppleAccountSession(
            keychain: keychain, defaults: #require(UserDefaults(suiteName: name)), namespace: name,
            applicationSupport: root, credentialState: { _ in .authorized })
    }
    func signIn(_ session: AppleAccountSession) {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        session.prepare(request)
        _ = session.completeSignIn(userID: "owner", state: request.state)
    }
    func remove() {
        for namespace in [name, scoped("owner"), scoped("other")] {
            UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

final class DeletionHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body: [String: Bool] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var input: [String: String] = [:]
    static var lastBody: [String: String] { lock.withLock { input } }
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(status: Int, body: [String: Bool]) {
        lock.withLock {
            Self.status = status
            Self.body = body
            recorded = []
            input = [:]
        }
    }
    static func respond(status: Int = 200, body: [String: Bool]) {
        lock.withLock {
            Self.status = status
            Self.body = body
        }
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try sendResponse()
        } catch {
            Issue.record("Could not create deletion HTTP stub response: \(error)")
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func sendResponse() throws {
        let url = try #require(request.url)
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, body) = Self.lock.withLock {
            Self.recorded.append(request)
            Self.input = (try? JSONDecoder().decode([String: String].self, from: bytes)) ?? [:]
            return (Self.status, Self.body)
        }
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        )
        var data = try JSONEncoder().encode(body)
        if url.path.hasSuffix("/challenge") {
            data = try JSONSerialization.data(withJSONObject: [
                "challengeID": String(repeating: "a", count: 64), "nonce": String(repeating: "b", count: 64),
                "deviceID": "11111111-1111-1111-1111-111111111111",
                "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000
            ])
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
