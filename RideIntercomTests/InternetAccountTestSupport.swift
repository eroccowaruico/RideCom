import CryptoKit
import Foundation
import RTC
import Testing

@testable import RideIntercom

@MainActor
final class InternetAccountTestFixture {
    let namespace = "RideIntercom.Tests.InternetAccount." + UUID().uuidString
    let deviceID = UUID().uuidString.lowercased()
    let keychain = InternetAccountTestKeychain()
    var currentUser = "apple-user"
    var saved: InternetAccountCredential?
    var savedIdentity: VerifiedDeviceIdentity?
    private lazy var storedSigningKey = Result {
        try InternetConnectionSettingsStore(keychain: keychain, namespace: namespace).deviceSigningKey()
    }
    var signingKey: P256.Signing.PrivateKey {
        get throws { try storedSigningKey.get() }
    }
    var saveFails = false
    var credential: InternetAccountCredential {
        .init(
            userID: String(repeating: "a", count: 64), deviceID: deviceID,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            accessToken: "ri1.\(String(repeating: "a", count: 64)).\(deviceID).\(String(repeating: "c", count: 64))"
        )
    }
    func makeAuthorization() throws -> InternetAccountAuthorization {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountHTTPStub.self]
        AccountHTTPStub.reset(deviceID: deviceID)
        return InternetAccountAuthorization(
            expectedUserID: "apple-user", deviceID: deviceID,
            memberID: "member-fixture",
            deviceKey: IdentityEncoding.encode(try signingKey.publicKey.x963Representation),
            client: InternetAccountClient(session: URLSession(configuration: configuration)),
            currentUser: { [unowned self] in currentUser },
            save: { [unowned self] _, value, identity in
                if saveFails { throw URLError(.cannotWriteToFile) }
                saved = value
                savedIdentity = identity
            })
    }
    func identity(
        userID: String = String(repeating: "a", count: 64),
        origin: String = "https://account.test"
    ) throws -> VerifiedDeviceIdentity {
        let certificate = try testIdentityCertificate(
            userID: userID, deviceID: deviceID,
            deviceKey: IdentityEncoding.encode(try signingKey.publicKey.x963Representation), origin: origin)
        return try certificate.verify(
            origin: #require(URL(string: origin)), trustedIssuerKey: certificate.issuerKey)
    }
    func saveDeviceID(_ deviceID: String) throws {
        try keychain.saveSecret(deviceID, service: namespace + ".InternetConnection", account: "device-id")
    }

    func remove() { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
}

final class InternetAccountTestKeychain: KeychainSecretStoring {
    var values: [String: String] = [:]
    var failDelete = false
    var failRead = false
    var failWrite = false
    var failWriteAccount: String?
    func accounts(service: String) throws -> [String] { Array(values.keys) }
    func secret(service: String, account: String) throws -> String? {
        if failRead { throw KeychainSecretStoreError.invalidData }
        return values[service + account]
    }
    func createSecretIfAbsent(_ value: String, service: String, account: String) throws -> String {
        if let retained = try secret(service: service, account: account) { return retained }
        try saveSecret(value, service: service, account: account)
        return value
    }
    func saveSecret(_ secret: String, service: String, account: String) throws {
        if failWrite || failWriteAccount == account { throw KeychainSecretStoreError.invalidData }
        values[service + account] = secret
    }
    func deleteSecret(service: String, account: String) throws {
        if failDelete { throw KeychainSecretStoreError.invalidData }
        values[service + account] = nil
    }
}

final class AccountHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var deviceID = ""
    nonisolated(unsafe) private static var identityChanges: [String: String] = [:]
    nonisolated(unsafe) private static var locator = String(repeating: "d", count: 64)
    nonisolated(unsafe) private static var delayed = false
    nonisolated(unsafe) private static var responseStatus = 200
    nonisolated(unsafe) private static var responsePath: String?
    nonisolated(unsafe) private static var responseCode: String?
    nonisolated(unsafe) private static var retryAfter: String?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset(deviceID: String) {
        lock.withLock {
            recorded = []
            Self.deviceID = deviceID
            delayed = false
            locator = String(repeating: "d", count: 64)
            responseStatus = 200
            responsePath = nil
            retryAfter = nil
            responseCode = nil
            identityChanges = [:]
        }
    }
    static func respond(status: Int, path: String? = nil, retryAfter: String? = nil, code: String? = nil) {
        lock.withLock {
            responseStatus = status
            responsePath = path
            Self.retryAfter = retryAfter
            responseCode = code
        }
    }
    static func changeIdentity(_ changes: [String: String]) { lock.withLock { identityChanges = changes } }
    static func setLocator(_ value: String) { lock.withLock { locator = value } }
    static func delayExchange() { lock.withLock { delayed = true } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try sendResponse()
        } catch {
            Issue.record("Could not create account HTTP stub response: \(error)")
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func sendResponse() throws {
        let url = try #require(request.url)
        let device = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.deviceID
        }
        let data = try responseData(url: url, device: device)
        let (status, retryAfter) = Self.lock.withLock {
            (
                Self.responsePath == nil || Self.responsePath == request.url?.path ? Self.responseStatus : 200,
                Self.retryAfter
            )
        }
        let response = try #require(
            HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] }
            )
        )
        let deliver: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.path == "/api/auth/apple/session", Self.lock.withLock({ Self.delayed }) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2, execute: deliver)
        } else {
            deliver()
        }
    }

    private func responseData(url: URL, device: String) throws -> Data {
        let account = String(repeating: "a", count: 64)
        var body: [String: Any]
        if url.path.hasSuffix("/challenge") {
            body = [
                "challengeID": account, "nonce": String(repeating: "b", count: 64), "deviceID": device,
                "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000
            ]
        } else if url.path.hasSuffix("/identity") {
            let input = Self.requestBody(request)
            let changes = Self.lock.withLock { Self.identityChanges }
            guard let origin = IdentityEncoding.origin(url) else { throw URLError(.badURL) }
            let proof = try testIdentityCertificate(
                deviceID: device, memberID: input["memberID"] as? String ?? "missing",
                deviceKey: input["deviceKey"] as? String ?? "missing", origin: origin,
                changes: changes)
            body = ["certificate": proof.certificate, "issuerKey": proof.issuerKey]
        } else if request.httpMethod == "DELETE" {
            body = [:]
        } else {
            body = [
                "userID": account, "deviceID": device,
                "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
                "accessToken":
                    "ri1.\(Self.lock.withLock { Self.locator }).\(device).\(String(repeating: "c", count: 64))"
            ]
        }
        if let code = Self.lock.withLock({ Self.responseCode }), Self.lock.withLock({ Self.responsePath }) == url.path {
            body = ["code": code]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func requestBody(_ request: URLRequest) -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
    override func stopLoading() {}
}
