import CryptoKit
#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    func workerSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
        return URLSession(configuration: configuration)
    }

    func withWorker(directRestore: Bool = false, _ exercise: () async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RideIntercom-GroupWorker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appendingPathComponent("port.json"),
            logFile = directory.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: logFile.path, contents: Data())
        let log = try FileHandle(forWritingTo: logFile), process = Process()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? log.close(); try? FileManager.default.removeItem(at: directory)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", root.appendingPathComponent("server/test/group-delivery-app-bridge.mjs").path, portFile.path
        ] + (directRestore ? ["--direct-restore"] : [])
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment; process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning,
            ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard FileManager.default.fileExists(atPath: portFile.path) else { throw WorkerFixtureFailure.unavailable }
        let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: portFile)) as? [String: Int])
        let port = try #require(fields["port"])
        guard let origin = URL(string: "http://127.0.0.1:\(port)") else { throw WorkerFixtureFailure.unavailable }
        GroupWorkerHTTPBridge.origin = origin
        defer { GroupWorkerHTTPBridge.origin = nil }
        try await exercise()
    }

    func register(_ peer: GroupDeliveryTestIdentity, appleSubject: String? = nil) async throws {
        struct Registration: Decodable {
            let credential: InternetAccountCredential; let identity: DeviceIdentityCertificate
        }
        var request = URLRequest(
            url: try #require(GroupWorkerHTTPBridge.origin).appendingPathComponent("fixture/register"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "memberID": peer.memberID, "deviceID": peer.store.accountDeviceID(),
            "appleSubject": appleSubject ?? peer.memberID,
            "deviceKey": IdentityEncoding.encode(peer.store.deviceSigningKey().publicKey.x963Representation)])
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let value = try JSONDecoder().decode(Registration.self, from: data)
        let identity = try value.identity.verify(
            origin: try #require(URL(string: "https://delivery.test")), trustedIssuerKey: value.identity.issuerKey)
        try peer.store.save(url: "https://delivery.test", token: value.credential.accessToken, identity: identity)
    }
}

private enum WorkerFixtureFailure: Error { case unavailable }

final class GroupWorkerHTTPBridge: URLProtocol, @unchecked Sendable {
    nonisolated static let ordinaryReplyInboxReads = Mutex(0)
    nonisolated static let contactAcceptanceWrites = Mutex(0)
    nonisolated static let holdNextRestoreDeviceRead = Mutex<ManualAsyncGate?>(nil)
    nonisolated static let interruptNextRestoreRetirement = Mutex(false)
    nonisolated static let interruptNextRestoreWithdrawal = Mutex(false)
    nonisolated static let interruptNextRestorePublication = Mutex(false)
    nonisolated static let restoreDevicePublicationAttempts = Mutex(0)
    nonisolated static let interruptNextRestoreRelayReply = Mutex(false)
    nonisolated static let restoreRelaySubmissionAttempts = Mutex(0)
    nonisolated(unsafe) static var origin: URL?
    struct Cancellation {
        let id: UUID
        let recipient: String
        let token: String
    }

    nonisolated(unsafe) static var cancellation: Cancellation?
    nonisolated(unsafe) static var cancellationResponse: String?
    nonisolated(unsafe) static var dropReceiptForID: UUID?
    nonisolated(unsafe) static var didDropReceipt = false
    nonisolated(unsafe) static var interruptOrdinaryGroupAcknowledgement = false
    private var requestWork: Task<Void, Never>?
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        if let stream = request.httpBodyStream { forwarded.httpBody = readBody(stream) }
        guard let base = Self.origin, let original = request.url else { return }
        if Self.interruptOrdinaryGroupAcknowledgement, original.path == "/api/ordinary-group-replies/acknowledgement" {
            Self.interruptOrdinaryGroupAcknowledgement = false
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if original.path == "/api/ordinary-group-replies/acceptance", request.httpMethod == "PUT" {
            Self.contactAcceptanceWrites.withLock { $0 += 1 }
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        components.path = original.path
        components.percentEncodedQuery =
            URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        forwarded.url = components.url
        let value = forwarded
        requestWork = Task { [self] in
            do {
                try Self.checkRestoreWrite(path: original.path, method: value.httpMethod)
                let (data, result) = try await URLSession.shared.data(for: value)
                let status = (result as? HTTPURLResponse)?.statusCode ?? 500
                try Self.checkRestoreReply(path: original.path, method: value.httpMethod, status: status)
                await Self.holdRestoreDeviceReadIfRequested(path: original.path, method: value.httpMethod)
                if status == 200, value.url?.path == "/api/ordinary-group-replies/inbox" {
                    Self.ordinaryReplyInboxReads.withLock { $0 += 1 }
                }
                if dropReceiptIfRequested(for: value, status: status, data: data) { return }
                try await cancelAfterDownloadIfRequested(for: value, data: data, origin: base)
                guard let response = HTTPURLResponse(
                    url: original, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])
                else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    private static func checkRestoreWrite(path: String, method: String?) throws {
        switch (path, method) {
        case ("/api/direct-call-restore/relay", "PUT"): restoreRelaySubmissionAttempts.withLock { $0 += 1 }
        case ("/api/direct-call-restore/relay", "DELETE"): try interruptIfRequested(interruptNextRestoreRetirement)
        case ("/api/direct-call-restore/device", "DELETE"): try interruptIfRequested(interruptNextRestoreWithdrawal)
        case ("/api/direct-call-restore/device", "PUT"):
            restoreDevicePublicationAttempts.withLock { $0 += 1 }
            try interruptIfRequested(interruptNextRestorePublication)
        default: break
        }
    }

    private static func checkRestoreReply(path: String, method: String?, status: Int) throws {
        guard path == "/api/direct-call-restore/relay", method == "PUT", status == 200 else { return }
        try interruptIfRequested(interruptNextRestoreRelayReply)
    }

    private static func interruptIfRequested(_ flag: borrowing Mutex<Bool>) throws {
        let interrupted = flag.withLock { value in
            defer { value = false }
            return value
        }
        if interrupted { throw URLError(.networkConnectionLost) }
    }
    private static func holdRestoreDeviceReadIfRequested(path: String, method: String?) async {
        guard path == "/api/direct-call-restore/device", method == "POST" else { return }
        await holdNextRestoreDeviceRead.withLock { value in
            defer { value = nil }
            return value
        }?.wait()
    }
    private func dropReceiptIfRequested(for value: URLRequest, status: Int, data: Data) -> Bool {
        if value.httpMethod == "DELETE", status == 200,
           let id = Self.dropReceiptForID, value.url?.lastPathComponent == id.uuidString.lowercased(),
            let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            receipt["status"] == "received" {
            Self.dropReceiptForID = nil
            Self.didDropReceipt = true
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return true
        }
        return false
    }

    private func cancelAfterDownloadIfRequested(for value: URLRequest, data: Data, origin: URL) async throws {
        if value.httpMethod == "GET", value.url?.path == "/api/notifications/group-invitations",
           let cancellation = Self.cancellation,
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let delivery = result["delivery"] as? [String: Any],
           let id = delivery["requestID"] as? String, UUID(uuidString: id) == cancellation.id {
            let path = "api/notifications/group-invitations/\(cancellation.recipient)/\(id)"
            var cancel = URLRequest(url: origin.appendingPathComponent(path))
            cancel.httpMethod = "DELETE"
            cancel.setValue("Bearer " + cancellation.token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: cancel)
            if (response as? HTTPURLResponse)?.statusCode == 200,
               let body = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                Self.cancellationResponse = body["status"]
            }
        }
    }

    private func readBody(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    override func stopLoading() { requestWork?.cancel() }
}
#endif
