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
        let revokedAfterDownload = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Cancelled after download", userIDs: [b.personID], id: revokedAfterDownload))
        let revokedGroupID = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Removed before receipt", userIDs: [b.personID], id: revokedGroupID))
        let cancelledBeforeSend = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Cancelled before arrival", userIDs: [b.personID], id: cancelledBeforeSend))
        let unsent = try #require(left.viewModel.groupRepository.groupDeliveries.first { $0.groupID == cancelledBeforeSend })
        let sender = try #require(try a.store.notificationAccess(memberID: a.memberID))
        // Exercise the same HTTP DELETE after an ambiguous upload, while the Worker has no row.
        try await client.finishGroupInvitation(recipient: unsent.recipient, id: unsent.id, access: sender)
        left.viewModel.groupDeliveryClient = client
        let group = try #require(left.viewModel.groups.first(where: { invitedGroups.contains($0.id) }))
        let call = left.viewModel.currentCallReference
        let recipientCall = right.viewModel.currentCallReference
        await left.viewModel.synchronizeGroupDeliveries()
        let author = left.viewModel
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == unsent.id })?.state == .cancelled)
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
        let afterDownload = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == revokedAfterDownload })
        #expect(afterDownload.state == .queued)
        GroupWorkerHTTPBridge.cancellation = (afterDownload.id, try b.principal.userID, sender.accessToken)
        let lostReceipt = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == group.id })
        GroupWorkerHTTPBridge.dropReceiptForID = lostReceipt.id
        defer {
            GroupWorkerHTTPBridge.cancellation = nil; GroupWorkerHTTPBridge.cancellationResponse = nil
            GroupWorkerHTTPBridge.dropReceiptForID = nil; GroupWorkerHTTPBridge.didDropReceipt = false
        }
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.didDropReceipt)
        #expect(!right.viewModel.groups.contains { $0.id == group.id })
        #expect(right.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == lostReceipt.id })?.state == .pending)
        #expect(right.viewModel.currentCallReference == recipientCall && left.viewModel.currentCallReference == call)
        right.viewModel.stopGroupDeliverySync(); right.viewModel.disconnect()
        let reopened = try b.harness(knowing: [a], onDisk: true)
        defer { reopened.viewModel.stopGroupDeliverySync(); reopened.viewModel.disconnect() }
        let receiver = reopened.viewModel
        #expect(!receiver.groups.contains { $0.id == group.id })
        let reopenedCall = receiver.currentCallReference
        receiver.groupDeliveryClient = client
        await receiver.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.cancellationResponse == "cancelled")
        #expect(!receiver.groups.contains { $0.id == revokedAfterDownload }, "Cancellation between downloading and saving should suppress the incoming group")
        #expect(try receiver.groupRepository.credential(for: revokedAfterDownload) == nil)
        #expect(receiver.groupRepository.groupDeliveries.first(where: { $0.id == afterDownload.id })?.credentialReference == nil)
        #expect(invitedGroups.isSubset(of: Set(receiver.groups.map(\.id))))
        #expect(receiver.groups.filter { $0.id == group.id }.count == 1)
        #expect(!receiver.groups.contains { $0.id == revokedGroupID })
        #expect(!receiver.groups.contains { $0.id == cancelledBeforeSend })
        #expect(receiver.currentCallReference == reopenedCall)
        #expect(receiver.activeGroupID == nil && !receiver.hasAnyActiveGroupConnection && reopened.callSession.connectedGroup == nil)
        let source = try #require(try left.viewModel.groupRepository.credential(for: group.id))
        let target = try #require(try receiver.groupRepository.credential(for: group.id))
        #expect(SHA256.hash(data: Data(source.secret.utf8)) == SHA256.hash(data: Data(target.secret.utf8)))
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.filter { $0.state == .received }.count == count)
        #expect(left.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == afterDownload.id })?.state == .cancelled)
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.credentialReference == nil })
        #expect(receiver.groupRepository.groupDeliveries.first(where: { $0.id == lostReceipt.id })?.state == .received)
        #expect(receiver.savedRemoteUsers.count == 1)

        let collision = UUID(), followUp = UUID()
        #expect(receiver.createTalkGroup(name: "Saved locally", id: collision))
        let localCredential = try #require(try receiver.groupRepository.credential(for: collision))
        let localCall = receiver.currentCallReference
        #expect(author.createTalkGroup(name: "Conflicting invitation", userIDs: [b.personID], id: collision))
        await author.synchronizeGroupDeliveries()
        let conflict = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == collision })
        #expect(conflict.state == .queued)
        await receiver.synchronizeGroupDeliveries()
        #expect(author.createTalkGroup(name: "Valid invitation after conflict", userIDs: [b.personID], id: followUp))
        await author.synchronizeGroupDeliveries()
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        let recipientAccess = try #require(try b.store.notificationAccess(memberID: b.memberID))
        #expect(try await client.acknowledgeGroupInvitation(conflict.id, access: recipientAccess) == .cancelled)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == conflict.id && $0.state != .cancelled })
        #expect(receiver.groups.first(where: { $0.id == followUp })?.name == "Valid invitation after conflict")
        #expect(receiver.groups.first(where: { $0.id == collision })?.name == "Saved locally")
        #expect(try receiver.groupRepository.credential(for: collision) == localCredential)
        #expect(receiver.currentCallReference == localCall && receiver.groupErrorMessage == nil)

        let person = try b.savedUser()
        let firstReceipt = try #require(author.groupInvitationDeliveries(in: followUp).first)
        #expect(firstReceipt.state == .received)
        #expect(author.removeMember(b.memberID, from: followUp))
        #expect(receiver.deleteGroup(followUp))
        #expect(author.addSavedUsers([person.id], to: followUp))
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(author.groupInvitationDeliveries(in: followUp).count == 1)
        let newDelivery = try #require(author.groupInvitationDeliveries(in: followUp).first { $0.id != firstReceipt.id })
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(!receiver.groups.contains { $0.id == followUp })
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveries(in: followUp).map(\.id) == [newDelivery.id])
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .received)
        #expect(receiver.groups.filter { $0.id == followUp }.count == 1)
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
    nonisolated(unsafe) static var cancellation: (id: UUID, recipient: String, token: String)?
    nonisolated(unsafe) static var cancellationResponse: String?
    nonisolated(unsafe) static var dropReceiptForID: UUID?
    nonisolated(unsafe) static var didDropReceipt = false
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
                if value.httpMethod == "DELETE", status == 200,
                   let id = Self.dropReceiptForID, value.url?.lastPathComponent == id.uuidString.lowercased(),
                   let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: String], receipt["status"] == "received" {
                    Self.dropReceiptForID = nil
                    Self.didDropReceipt = true
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                if value.httpMethod == "GET", value.url?.path == "/api/notifications/group-invitations",
                   let cancellation = Self.cancellation,
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let delivery = result["delivery"] as? [String: Any],
                   let id = delivery["requestID"] as? String, UUID(uuidString: id) == cancellation.id {
                    let path = "api/notifications/group-invitations/\(cancellation.recipient)/\(id)"
                    var cancel = URLRequest(url: base.appendingPathComponent(path))
                    cancel.httpMethod = "DELETE"
                    cancel.setValue("Bearer " + cancellation.token, forHTTPHeaderField: "Authorization")
                    let (data, response) = try await URLSession.shared.data(for: cancel)
                    if (response as? HTTPURLResponse)?.statusCode == 200,
                       let body = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                        Self.cancellationResponse = body["status"]
                    }
                }
                let response = HTTPURLResponse(url: original, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { requestWork?.cancel() }
}
#endif
