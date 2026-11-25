import CallControl
import CryptoKit
import Foundation
import RTC
import SessionManager
import Synchronization
import Testing
import UserNotifications
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct NotificationClientTests {
    let origin = URL(string: "https://notify.test")!
    let token =
        "ri1." + String(repeating: "a", count: 64) + ".00000000-0000-0000-0000-000000000001."
        + String(repeating: "b", count: 64)
    let userID = String(repeating: "c", count: 64)
    var notificationAccess: CallNotificationServiceAccess {
        .init(origin: origin, accessToken: token, principal: .init(issuer: origin.absoluteString, userID: userID))
    }

    @Test func groupInvitationAcknowledgementUsesOnlyTheCurrentDeleteResponse() async throws {
        let client = makeClient()
        let fixture = try NotificationModelFixture(client: client); defer { fixture.remove() }
        let access = try #require(try fixture.store.notificationAccess(memberID: "local"))
        let id = UUID()

        NotificationHTTPStub.setRawResponse("{}")
        await #expect(throws: DecodingError.self) {
            try await client.acknowledgeGroupInvitation(id, access: access)
        }
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])

        NotificationHTTPStub.requests = []
        NotificationHTTPStub.status = 404
        #expect(try await client.acknowledgeGroupInvitation(id, access: access) == nil)
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])

        NotificationHTTPStub.requests = []
        NotificationHTTPStub.status = 200
        NotificationHTTPStub.setRawResponse(#"{"status":"received"}"#)
        #expect(try await client.acknowledgeGroupInvitation(id, access: access) == .received)
        #expect(NotificationHTTPStub.requests.map(\.httpMethod) == ["DELETE"])
    }

    @Test func deviceRegistrationAndRemovalUseOnlyNativeNotificationFields() async throws {
        let client = makeClient()
        NotificationHTTPStub.setRawResponse("{\"registered\":true}")
        try await client.registerNotificationDevice(
            access: notificationAccess, deviceToken: Data([0, 255, 8]), environment: "sandbox",
            topic: "fixture.app", revision: 1)
        var request = try #require(NotificationHTTPStub.requests.last)
        #expect(request.httpMethod == "PUT" && request.url?.path == "/api/notifications/device")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token)
        #expect(request.value(forHTTPHeaderField: "RideCom-Notification-Revision") == "1")
        let fields = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(fields == ["token": "00ff08", "environment": "sandbox", "topic": "fixture.app"])
        NotificationHTTPStub.setRawResponse("{}")
        try await client.removeNotificationDevice(access: notificationAccess, revision: 2)
        request = try #require(NotificationHTTPStub.requests.last)
        #expect(request.httpMethod == "DELETE" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "RideCom-Notification-Revision") == "2")
    }

    @Test func capabilityAndCallRequestsNeverSendNamesOrGroupData() async throws {
        let client = makeClient(), grantID = UUID(), requestID = UUID()
        NotificationHTTPStub.setRawResponse("{\"grantID\":\"\(grantID)\",\"capability\":\"opaque.signed.capability\"}")
        let grant = try await client.issueNotificationGrant(origin: origin, token: token, senderUserID: userID)
        #expect(grant.grantID == grantID)
        let issue = try #require(NotificationHTTPStub.requests.last)
        #expect(
            try JSONSerialization.jsonObject(with: try #require(issue.httpBody)) as? [String: String] == [
                "senderUserID": userID
            ])
        let expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
        NotificationHTTPStub.setRawResponse(
            "{\"requestID\":\"\(requestID)\",\"expiresAt\":\(expiresAt),\"status\":\"accepted\"}")
        let result = try await client.sendCallNotification(
            origin: origin, token: token, capability: grant.capability, requestID: requestID)
        #expect(result.status == .accepted)
        let sent = try #require(NotificationHTTPStub.requests.last)
        #expect(
            try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String] == [
                "capability": grant.capability, "requestID": requestID.uuidString.lowercased()
            ])
        #expect(result.status != .cancelled)
    }

    @Test func tapLookupAndCancellationUseRecipientAndRequestAndRejectExpiredServerResponses() async throws {
        let client = makeClient(), requestID = UUID()
        let expiresAt = Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
        NotificationHTTPStub.setRawResponse(
            "{\"requestID\":\"\(requestID)\",\"expiresAt\":\(expiresAt),"
                + "\"status\":\"accepted\",\"senderUserID\":\"\(userID)\"}")
        let result = try await client.readCallNotification(
            origin: origin, token: token, recipientUserID: userID, requestID: requestID)
        #expect(result.senderUserID == userID)
        #expect(NotificationHTTPStub.requests.last?.httpMethod == "GET")
        NotificationHTTPStub.status = 410
        await #expect(throws: (any Error).self) {
            try await client.readCallNotification(
                origin: origin, token: token, recipientUserID: userID, requestID: requestID)
        }
    }

    @Test func malformedGrantAndUnexpectedCallStatusesAreRejected() async {
        let client = makeClient()
        NotificationHTTPStub.setRawResponse("{\"grantID\":\"\(UUID())\",\"capability\":\"\"}")
        await #expect(throws: (any Error).self) {
            try await client.issueNotificationGrant(origin: origin, token: token, senderUserID: userID)
        }
        NotificationHTTPStub.setRawResponse("{\"requestID\":\"\(UUID())\",\"expiresAt\":1,\"status\":\"delivered\"}")
        await #expect(throws: (any Error).self) {
            try await client.sendCallNotification(
                origin: origin, token: token, capability: "opaque", requestID: UUID())
        }
    }
    func notificationHarness(
        _ fixture: NotificationModelFixture,
        requestMicrophoneAccess: @escaping @MainActor () async -> Bool = { true },
        callMicrophonePermission: @escaping @MainActor () -> CallMicrophonePermission = { .granted }
    ) -> AppTestSupport.Harness {
        let groups = InMemoryGroupStore(groups: [])
        groups.snapshot.users = fixture.users
        let harness = AppTestSupport.makeHarness(
            groups: [], groupStore: groups, internetSettingsStore: fixture.store, localMemberID: "local",
            callAccessNow: { fixture.now }, requestMicrophoneAccess: requestMicrophoneAccess,
            callMicrophonePermission: callMicrophonePermission)
        let model = harness.viewModel
        fixture.permitsDeviceRegistration = { [weak model] in model?.permitsNotificationDeviceRegistration == true }
        model.notifications = fixture.notifications
        return harness
    }

    func makeClient() -> InternetAccountClient {
        NotificationHTTPStub.requests = []; NotificationHTTPStub.status = 200
        NotificationHTTPStub.delayGate = nil; NotificationHTTPStub.echoCallStatus = nil
        NotificationHTTPStub.cancelledRequests.withLock { $0.removeAll() }
        NotificationHTTPStub.cancelledDeviceMethods.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationHTTPStub.self]
        return InternetAccountClient(session: URLSession(configuration: configuration))
    }
}

final class NotificationHTTPStub: URLProtocol, @unchecked Sendable {
    nonisolated static let cancelledRequests = Mutex(Set<UUID>())
    nonisolated static let cancelledDeviceMethods = Mutex([String]())
    private let stopped = Mutex(false)
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) private static var responseBody = Data("{}".utf8)
    static func setJSONResponse(_ value: some Encodable) throws {
        responseBody = try JSONEncoder().encode(value)
    }
    static func setRawResponse(_ json: String) {
        responseBody = Data(json.utf8)
    }
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var delayGate: ManualAsyncGate?
    nonisolated(unsafe) static var echoCallStatus: CallNotificationStatus?
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "notify.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        Self.requests.append(captured)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data: Data
        if let status = Self.echoCallStatus, captured.httpMethod == "POST",
            captured.url?.path == "/api/notifications/calls",
            let body = captured.httpBody,
            let fields = try? JSONSerialization.jsonObject(with: body) as? [String: String],
           let id = fields["requestID"] {
            let fields: [String: Any] = [
                "requestID": id, "status": status.rawValue,
                "expiresAt": Date().addingTimeInterval(120).timeIntervalSince1970 * 1000
            ]
            do {
                data = try JSONSerialization.data(withJSONObject: fields)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        } else {
            data = Self.responseBody
        }
        let gate = Self.delayGate
        Task { @MainActor [self] in
            if let gate { await gate.wait() }
            guard !stopped.withLock({ $0 }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        stopped.withLock { $0 = true }
        if let id = request.url.flatMap({ UUID(uuidString: $0.lastPathComponent) }) {
            Self.cancelledRequests.withLock { _ = $0.insert(id) }
        }
        if request.url?.path == "/api/notifications/device", let method = request.httpMethod {
            Self.cancelledDeviceMethods.withLock { $0.append(method) }
        }
    }
}

@MainActor
final class NotificationModelFixture {
    let namespace = "RideIntercom.NotificationTest." + UUID().uuidString
    let keychain = DictionaryKeychain()
    let store: InternetConnectionSettingsStore
    let local = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
    let peer = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "c", count: 64))
    let peerSigner: DeviceIdentitySigner
    let client: InternetAccountClient
    var current = true, permission = true, registerCount = 0, unregisterCount = 0
    var permitsDeviceRegistration: @MainActor () -> Bool = { true }
    var authorizationGate: ManualAsyncGate?
    var users: [SavedUser] = []
    var now = Date()
    var user: SavedUser { users[0] }
    lazy var notifications = CallNotifications(store: store, memberID: "local", client: client,
        isCurrentUser: { [unowned self] in current }, contacts: { [unowned self] in users },
        permitsDeviceRegistration: { [unowned self] in permitsDeviceRegistration() },
        requestAuthorization: { [unowned self] in
            if let authorizationGate { await authorizationGate.wait() }; return permission
        },
        authorizationGranted: { [unowned self] in permission }, register: { [unowned self] in registerCount += 1 },
        unregister: { [unowned self] in unregisterCount += 1 }, now: { [unowned self] in now })
    init(client: InternetAccountClient) throws {
        self.client = client
        peerSigner = try DeviceIdentitySigner(memberID: "friend", key: .init())
        store = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let deviceID = try store.accountDeviceID()
        let key = try store.deviceSigningKey()
        let envelope = try testIdentityCertificate(userID: local.userID, deviceID: deviceID, memberID: "local",
            deviceKey: IdentityEncoding.encode(key.publicKey.x963Representation), origin: local.issuer)
        let origin = try #require(URL(string: local.issuer))
        let identity = try envelope.verify(origin: origin, trustedIssuerKey: envelope.issuerKey)
        try store.save(
            url: local.issuer,
            token: "ri1." + String(repeating: "d", count: 64) + "." + deviceID + "."
                + String(repeating: "e", count: 64), identity: identity)
        users = [
            SavedUser(
                displayName: "Never send this name", memberIDs: ["friend"],
                deviceKeys: ["friend": peerSigner.publicKey], principal: peer)
        ]
    }
    func remove() { UserDefaults(suiteName: namespace)?.removePersistentDomain(forName: namespace) }
}
