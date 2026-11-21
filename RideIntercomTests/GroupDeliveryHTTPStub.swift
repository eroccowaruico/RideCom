import Foundation
import Testing
@testable import RideIntercom

final class GroupDeliveryHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var users: [String: String] = [:]
    nonisolated(unsafe) static var items: [String: [String: Any]] = [:]
    nonisolated(unsafe) static var submitted: [String] = []
    @MainActor static var deletions: [String] = []
    @MainActor static var statusLookups: [String] = []
    @MainActor static var failNextStatus = false
    nonisolated(unsafe) static var onQueued: (@MainActor () -> Void)?
    nonisolated(unsafe) static var onAcknowledged: (@MainActor () -> Void)?
    @MainActor static var beforeReturningInbox: (@MainActor () async -> Void)?
    @MainActor static var onContactDeletion: ((URLRequest, String) -> (Int, [String: Any]))?
    nonisolated(unsafe) static var rejectedRecipientID: String?
    nonisolated(unsafe) static var submitRejectionStatus = 403
    nonisolated(unsafe) static var failNextSubmit = false
    nonisolated(unsafe) static var failNextAcknowledgement = false

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }

    @MainActor static func reset() {
        requestCount = 0
        users = [:]
        items = [:]
        submitted = []
        deletions = []
        statusLookups = []
        failNextStatus = false
        rejectedRecipientID = nil
        submitRejectionStatus = 403
        failNextSubmit = false
        failNextAcknowledgement = false
        onQueued = nil
        onAcknowledged = nil
        beforeReturningInbox = nil
        onContactDeletion = nil
    }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        var captured = request
        if let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size <= 0 { break }
                body.append(contentsOf: buffer.prefix(size))
            }
            captured.httpBody = body
        }
        let value = captured
        Task { @MainActor [self] in
            let (status, object) = Self.respond(value)
            if object["delivery"] != nil, let beforeReturningInbox = Self.beforeReturningInbox {
                Self.beforeReturningInbox = nil
                await beforeReturningInbox()
            }
            guard let url = value.url, let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ), let body = try? JSONSerialization.data(withJSONObject: object) else {
                Issue.record("The group delivery fixture could not construct an HTTP response")
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    @MainActor private static func respond(_ request: URLRequest) -> (Int, [String: Any]) {
        let bearer = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        guard let caller = users[bearer], let url = request.url else { return (401, [:]) }
        if url.path.hasPrefix("/api/contact-deletions") { return onContactDeletion?(request, caller) ?? (404, [:]) }
        if request.httpMethod == "POST" {
            return submit(request, caller: caller)
        }
        if request.httpMethod == "GET", url.path == "/api/notifications/group-invitations" {
            return inbox(url, caller: caller)
        }
        if request.httpMethod == "GET", url.pathComponents.count == 6,
           url.path.hasPrefix("/api/notifications/group-invitations/") {
            return status(for: url.lastPathComponent, caller: caller)
        }
        if request.httpMethod == "DELETE" {
            return finish(url, caller: caller)
        }
        return (404, [:])
    }

    @MainActor private static func submit(_ request: URLRequest, caller: String) -> (Int, [String: Any]) {
        guard let body = request.httpBody,
           let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let id = fields["requestID"] as? String, let expiry = fields["expiresAt"] as? Double,
           let encoded = fields["envelope"] as? String, let data = Data(base64Encoded: encoded),
           let envelope = try? JSONDecoder().decode(GroupInvitationEnvelope.self, from: data) else {
            return (404, [:])
        }
        submitted.append(encoded)
        if envelope.recipient.userID == rejectedRecipientID { return (submitRejectionStatus, [:]) }
        if failNextSubmit {
            failNextSubmit = false
            return (503, [:])
        }
        if let old = items[id] {
            guard old["envelope"] as? String == encoded else { return (409, [:]) }
            return (200, ["requestID": id, "expiresAt": expiry, "status": requiredField("status", in: old)])
        }
        items[id] = ["requestID": id, "expiresAt": expiry, "status": "queued", "senderUserID": caller,
            "recipientID": envelope.recipient.userID, "recipientKey": envelope.recipientKey, "envelope": encoded]
        onQueued?()
        return (200, ["requestID": id, "expiresAt": expiry, "status": "queued"])
    }

    @MainActor private static func inbox(_ url: URL, caller: String) -> (Int, [String: Any]) {
        let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        let item = items.values.first {
            $0["recipientID"] as? String == caller && $0["recipientKey"] as? String == key
                && $0["status"] as? String == "queued"
        }
        return (200, ["delivery": item.map { $0 as Any } ?? NSNull()])
    }

    @MainActor private static func status(for id: String, caller: String) -> (Int, [String: Any]) {
        statusLookups.append(id)
        if failNextStatus {
            failNextStatus = false
            return (503, [:])
        }
        guard let item = items[id], item["senderUserID"] as? String == caller else { return (404, [:]) }
        return (200, [
            "requestID": id,
            "expiresAt": requiredField("expiresAt", in: item),
            "status": requiredField("status", in: item)
        ])
    }

    @MainActor private static func finish(_ url: URL, caller: String) -> (Int, [String: Any]) {
        deletions.append(url.lastPathComponent)
        if failNextAcknowledgement {
            failNextAcknowledgement = false
            return (503, [:])
        }
        let id = url.lastPathComponent
        guard var item = items[id] else { return (404, [:]) }
        if item["status"] as? String == "queued" {
            let discard =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(
                    .init(name: "discard", value: "1")) == true
            item["status"] = item["recipientID"] as? String == caller && !discard ? "received" : "cancelled"
            items[id] = item
            if item["status"] as? String == "received" {
                let action = onAcknowledged
                onAcknowledged = nil
                action?()
            }
        }
        return (200, ["status": requiredField("status", in: item)])
    }

    private static func requiredField(_ key: String, in item: [String: Any]) -> Any {
        guard let value = item[key] else {
            Issue.record("The group delivery fixture is missing the expected field: \(key)")
            return NSNull()
        }
        return value
    }

    override func stopLoading() {}
}
