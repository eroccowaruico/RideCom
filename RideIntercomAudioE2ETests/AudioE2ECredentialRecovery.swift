import CryptoKit
import Foundation
import RTC
import Synchronization
import XCTest
@testable import RideIntercom

nonisolated enum AudioE2ECredentialRecovery {
    static func rejectedToken(run: String) -> String { run + "-expired" }
    static func replacementToken(run: String) -> String {
        "ri1.\(accountID).\(run.lowercased()).\(String(repeating: "c", count: 64))"
    }
    fileprivate static let accountID = String(repeating: "a", count: 64)
    fileprivate static let nonce = String(repeating: "b", count: 64)

    @MainActor
    static func configure(_ model: IntercomViewModel, run: AudioE2ENetworkRun, origin: URL?) {
        guard run.rejectsInitialCredential, let origin else { return }
        RegistrationResponse.configure(origin: origin, run: run.identifier)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegistrationResponse.self]
        model.automaticInternetEnrollment.client = InternetAccountClient(
            session: URLSession(configuration: configuration))
    }
    static var requests: [String] { RegistrationResponse.requests }
}

private nonisolated final class RegistrationResponse: URLProtocol, @unchecked Sendable {
    private struct Trial {
        let origin: String
        let run: String
        var requests: [String] = []
    }
    private static let trial = Mutex<Trial?>(nil)
    static var requests: [String] { trial.withLock { $0?.requests ?? [] } }
    static func configure(origin: URL, run: String) {
        trial.withLock { $0 = .init(origin: origin.absoluteString, run: run) }
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            guard let url = request.url, request.httpMethod == "POST",
                  let trial = Self.trial.withLock({ $0 }), IdentityEncoding.origin(url) == trial.origin
            else { throw URLError(.badURL) }
            let body = try response(at: url.path, trial: trial)
            Self.trial.withLock { $0?.requests.append(url.path) }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: ["Content-Type": "application/json"])
            else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func response(at path: String, trial: Trial) throws -> Data {
        let deviceID = trial.run.lowercased()
        let account = AudioE2ECredentialRecovery.accountID
        let token = AudioE2ECredentialRecovery.replacementToken(run: trial.run)
        let now = floor(Date().timeIntervalSince1970)
        let body = try requestBody()
        switch path {
        case "/api/auth/apple/challenge":
            guard body["deviceID"] as? String == deviceID else { throw URLError(.cannotDecodeContentData) }
            return try JSONSerialization.data(withJSONObject: [
                "challengeID": account, "nonce": AudioE2ECredentialRecovery.nonce,
                "deviceID": deviceID, "expiresAt": (now + 300) * 1000
            ])
        case "/api/auth/apple/session":
            guard body["challengeID"] as? String == account, body["signInProof"] is [String: String],
                  body["identityToken"] is String else { throw URLError(.cannotDecodeContentData) }
            return try JSONEncoder().encode(InternetAccountCredential(
                userID: account, deviceID: deviceID, expiresAt: (now + 604_800) * 1000, accessToken: token))
        case "/api/auth/identity":
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)",
                  let memberID = body["memberID"] as? String, let deviceKey = body["deviceKey"] as? String
            else { throw URLError(.cannotDecodeContentData) }
            return try certificate(trial: trial, memberID: memberID, deviceKey: deviceKey, now: now)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func certificate(trial: Trial, memberID: String, deviceKey: String, now: Double) throws -> Data {
        let issuer = P256.Signing.PrivateKey()
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "rideintercom-device+jwt"])
        let claims = try JSONSerialization.data(withJSONObject: [
            "iss": trial.origin, "sub": AudioE2ECredentialRecovery.accountID, "aud": "rideintercom-peer",
            "deviceID": trial.run.lowercased(), "memberID": memberID, "deviceKey": deviceKey,
            "iat": now, "exp": now + 518_400
        ])
        let payload = IdentityEncoding.encode(header) + "." + IdentityEncoding.encode(claims)
        let signature = try issuer.signature(for: Data(payload.utf8))
        return try JSONEncoder().encode(DeviceIdentityCertificate(
            certificate: payload + "." + IdentityEncoding.encode(signature.rawRepresentation),
            issuerKey: IdentityEncoding.encode(issuer.publicKey.x963Representation)))
    }

    private func requestBody() throws -> [String: Any] {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, bytes.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
}

extension AudioE2EEndpoint {
    @MainActor
    func verifyCredentialRecovery() async throws {
        guard run.recoversRejectedCredential, run.role == "a" else { return }
        let call = try XCTUnwrap(viewModel.currentCallReference)
        let deadline = viewModel.callDisconnectDeadline
        let service = try XCTUnwrap(worker.fixture)
        viewModel.groupDeliveryNetworkPathChanged(isAvailable: true)
        try await waitUntil(seconds: 30, description: "Reregister rejected credential", status: status) {
            guard (try? viewModel.internetSettingsStore.load()?.accessToken)
                == AudioE2ECredentialRecovery.replacementToken(run: run.identifier) else { return false }
            let counts = await service.measurements()["requests"] as? [String: Int]
            return (counts?["replacement-ice"] ?? 0) > 0 && (counts?["replacement-join"] ?? 0) > 0
        }
        let counts = await service.measurements()["requests"] as? [String: Int]
        XCTAssertEqual(counts?["credential-rejected"], 1)
        XCTAssertEqual(AudioE2ECredentialRecovery.requests, [
            "/api/auth/apple/challenge", "/api/auth/apple/session", "/api/auth/identity"
        ])
        XCTAssertEqual(viewModel.currentCallReference, call)
        XCTAssertEqual(viewModel.callDisconnectDeadline, deadline)
        XCTAssertNil(viewModel.internetTransportFailure)
    }
}
