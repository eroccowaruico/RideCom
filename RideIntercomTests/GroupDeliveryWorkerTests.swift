#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)), arguments: [1, 9]) func theActualWorkerDeliversAndAcknowledgesAGroupWithoutStartingTheRecipientsCall(count: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RideIntercom-GroupWorker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appendingPathComponent("port.json"), logFile = directory.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: logFile.path, contents: Data())
        let log = try FileHandle(forWritingTo: logFile), process = Process()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? log.close(); try? FileManager.default.removeItem(at: directory)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("server/test/group-delivery-app-bridge.mjs").path, portFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment; process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard FileManager.default.fileExists(atPath: portFile.path) else { throw WorkerFixtureFailure.unavailable }
        let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: portFile)) as? [String: Int])
        let port = try #require(fields["port"])
        GroupWorkerHTTPBridge.origin = URL(string: "http://127.0.0.1:\(port)")!
        defer { GroupWorkerHTTPBridge.origin = nil }
        let a = GroupDeliveryTestIdentity("worker-author"), b = GroupDeliveryTestIdentity("worker-recipient")
        defer { a.remove(); b.remove() }
        try await register(a); try await register(b)
        let left = try a.harness(knowing: [b], onDisk: true), right = try b.harness(knowing: [a], onDisk: true)
        defer { left.viewModel.stopGroupDeliverySync(); right.viewModel.stopGroupDeliverySync(); left.viewModel.disconnect(); right.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        left.viewModel.groupDeliveryClient = nil; right.viewModel.groupDeliveryClient = client
        right.viewModel.notifications = CallNotifications(store: b.store, memberID: b.memberID, client: client,
            isCurrentUser: { [weak model = right.viewModel] in model?.canStartCalls == true }, contacts: { [weak model = right.viewModel] in model?.savedRemoteUsers ?? [] })
        await right.viewModel.notifications.allowGroupInvitations()
        let permission = try #require(try right.viewModel.notifications.groupPermissionMessage(for: a.memberID, signer: b.signer))
        #expect(permission.groupGrant != nil)
        try left.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        var invitedGroups = Set<UUID>()
        for index in 0..<count {
            let id = UUID(); invitedGroups.insert(id)
            #expect(left.viewModel.createTalkGroup(name: "Actual Worker group \(index)", userIDs: [b.personID], id: id))
        }
        let revokedGroupID = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Removed before receipt", userIDs: [b.personID], id: revokedGroupID))
        left.viewModel.groupDeliveryClient = client
        let group = try #require(left.viewModel.groups.first(where: { invitedGroups.contains($0.id) }))
        let call = left.viewModel.currentCallReference
        let recipientCall = right.viewModel.currentCallReference
        await left.viewModel.synchronizeGroupDeliveries()
        let author = left.viewModel
        let revoked = try #require(author.groupRepository.groupDeliveries.first(where: { $0.groupID == revokedGroupID }))
        #expect(revoked.state == .queued)
        var requested = 0, released = 0
        author.beginGroupDeliveryBackgroundTime = { _ in
            requested += 1
            return { released += 1 }
        }
        author.removeMember(b.memberID, from: revokedGroupID)
        #expect(requested == 1, "Request time before returning from the removal")
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == revoked.id })?.state == .cancelled)
        await author.groupDeliveryTask?.value
        #expect(released == 1)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == revoked.id })
        #expect(author.savedRemoteUsers.contains { $0.id == b.personID })
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(invitedGroups.isSubset(of: Set(right.viewModel.groups.map(\.id))))
        #expect(!right.viewModel.groups.contains { $0.id == revokedGroupID })
        #expect(right.viewModel.currentCallReference == recipientCall && left.viewModel.currentCallReference == call)
        #expect(right.viewModel.activeGroupID == nil && !right.viewModel.hasAnyActiveGroupConnection && right.callSession.connectedGroup == nil)
        let source = try #require(try left.viewModel.groupRepository.credential(for: group.id))
        let target = try #require(try right.viewModel.groupRepository.credential(for: group.id))
        #expect(SHA256.hash(data: Data(source.secret.utf8)) == SHA256.hash(data: Data(target.secret.utf8)))
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.count == count)
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.state == .received })
        #expect(left.viewModel.groupRepository.groupDeliveries.first?.credentialReference == nil)
        right.viewModel.stopGroupDeliverySync(); right.viewModel.disconnect()
        let reopened = try b.harness(knowing: [a], onDisk: true)
        defer { reopened.viewModel.stopGroupDeliverySync(); reopened.viewModel.disconnect() }
        #expect(invitedGroups.isSubset(of: Set(reopened.viewModel.groups.map(\.id))))
        #expect(reopened.viewModel.groupRepository.groupDeliveries.first?.state == .received)
        #expect(reopened.viewModel.savedRemoteUsers.count == 1)
    }
    private func register(_ peer: GroupDeliveryTestIdentity) async throws {
        struct Registration: Decodable { let credential: InternetAccountCredential; let identity: DeviceIdentityCertificate }
        var request = URLRequest(url: try #require(GroupWorkerHTTPBridge.origin).appendingPathComponent("fixture/register"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["memberID": peer.memberID, "deviceID": peer.store.accountDeviceID(),
            "deviceKey": IdentityEncoding.encode(peer.store.deviceSigningKey().publicKey.x963Representation)])
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let value = try JSONDecoder().decode(Registration.self, from: data)
        let identity = try value.identity.verify(origin: URL(string: "https://delivery.test")!, trustedIssuerKey: value.identity.issuerKey)
        try peer.store.save(url: "https://delivery.test", token: value.credential.accessToken, identity: identity)
    }
}
private enum WorkerFixtureFailure: Error { case unavailable }

private final class GroupWorkerHTTPBridge: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var origin: URL?
    private var requestWork: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            forwarded.httpBody = data
        }
        guard let base = Self.origin, let original = request.url else { return }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = original.path; components.percentEncodedQuery = URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        forwarded.url = components.url
        let value = forwarded
        requestWork = Task { [self] in
            do {
                let (data, result) = try await URLSession.shared.data(for: value)
                let status = (result as? HTTPURLResponse)?.statusCode ?? 500
                let response = HTTPURLResponse(url: original, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { requestWork?.cancel() }
}
#endif
