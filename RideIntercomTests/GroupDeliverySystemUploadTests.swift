#if os(iOS)
import CallControl
import CryptoKit
import Foundation
import Network
import RTC
import Synchronization
import Testing
@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test(.timeLimit(.minutes(2))) func systemBackgroundSessionPublishesSavedContactDeletion() async throws {
        let author = GroupDeliveryTestIdentity("native-delete-author")
        let recipient = GroupDeliveryTestIdentity("native-delete-recipient")
        defer { author.remove(); recipient.remove() }
        let issuer = P256.Signing.PrivateKey()
        try author.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer, relayEnabled: true)
        try recipient.authorizeFixture(userID: String(repeating: "b", count: 64), issuer: issuer)
        let sender = try author.harness(knowing: [], onDisk: true).viewModel
        let receiver = try recipient.harness(knowing: []).viewModel
        defer { sender.stopGroupDeliverySync(); receiver.stopGroupDeliverySync() }
        for model in [sender, receiver] {
            model.groupDeliveryClient = nil
            model.contactSessionFactory = { RecordingCallSession() }
        }
        try establishContact(sender: sender, recipient: receiver)
        let recording = RecordingBackgroundInvitationTransfer()
        sender.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        sender.invitationBackgroundTransfer = recording
        try #require(sender.removeSavedUser(try #require(sender.savedRemoteUsers.first).id))
        await sender.synchronizeGroupDeliveries()
        let publication = try #require(sender.groupRepository.contactDeletionPublications.first)
        let key = try #require(recording.enqueued.first)
        var request = try #require(recording.requests[key])
        #expect(key.operation == .contactDeletion)
        let body = try #require(request.httpBody)
        #expect(containsOnlySealedInvitation(
            body, excluding: [publication.slot, publication.id.uuidString.lowercased()]))

        let owner = AppCallOwner(account: sender.accountSession, viewModel: sender)
        let transfer = InvitationBackgroundTransfer.shared
        transfer.bind(to: owner)
        await transfer.restore()
        defer { transfer.reconcile(keeping: []) }
        sender.invitationBackgroundTransfer = transfer
        let reply = try JSONEncoder().encode(["state": "pending"])
        try await checkBackgroundUpload(request: &request, key: key, reply: reply, transfer: transfer)
        #expect(sender.groupRepository.contactDeletionPublications.first?.payload?.backgroundPublished == true)
        #expect(sender.groupRepository.contactDeletions.map(\.id) == [publication.id])
        #expect(owner.viewModel === sender)
    }

    @Test(.timeLimit(.minutes(2))) func systemBackgroundSessionSendsTheCopiedFileAndAppliesTheReply() async throws {
        let authorDevice = GroupDeliveryTestIdentity("native-upload-author")
        let recipientDevice = GroupDeliveryTestIdentity("native-upload-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        let issuer = P256.Signing.PrivateKey()
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer, relayEnabled: true)
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64), issuer: issuer)
        let model = try authorDevice.harness(knowing: [recipientDevice]).viewModel
        model.groupDeliveryClient = nil
        try grantGroupInvitationPermission(on: model, recipient: recipientDevice, sender: authorDevice)
        try #require(model.createTalkGroup(name: "System upload", userIDs: [recipientDevice.personID]))
        let record = try #require(model.groupRepository.groupDeliveries.first)
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        let locator = try #require(access.accessToken.split(separator: ".").dropFirst().first)
        let excluded = [
            access.accessToken, String(locator), try authorDevice.principal.userID,
            try recipientDevice.principal.userID,
            record.id.uuidString.lowercased(), authorDevice.memberID, recipientDevice.memberID
        ]
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        let transfer = InvitationBackgroundTransfer.shared
        transfer.bind(to: owner)
        await transfer.restore()
        defer { transfer.reconcile(keeping: []) }
        for operation in [InvitationBackgroundUploadID.Operation.send, .cancel] {
            let key = try #require(model.backgroundInvitationUploadIDs().first)
            #expect(key.operation == operation)
            var request = try #require(try model.backgroundGroupInvitationRequest(for: key.deliveryID))
            let reply = try JSONSerialization.data(withJSONObject: [
                "requestID": record.id.uuidString.lowercased(),
                "expiresAt": record.expiresAt * 1_000, "status": operation == .send ? "queued" : "cancelled"
            ])
            let beforeRedirect = model.groupRepository.groupDeliveries
            try await checkBackgroundRedirect(
                request: request, key: key, reply: reply, transfer: transfer, excluded: excluded)
            #expect(model.groupRepository.groupDeliveries == beforeRedirect)
            try await checkBackgroundUpload(request: &request, key: key, reply: reply, transfer: transfer)
            if operation == .send {
                #expect(model.groupRepository.groupDeliveries.first?.state == .queued)
                try #require(model.removeMember(recipientDevice.memberID, from: record.groupID))
            } else {
                #expect(model.groupRepository.groupDeliveries.isEmpty)
            }
        }
        try await checkContactAcceptanceUpload(
            on: model, authorDevice: authorDevice, recipientDevice: recipientDevice, transfer: transfer
        )
        // Keep the account owner alive while the session delivers its completion.
        #expect(owner.viewModel === model)
    }

    private func checkContactAcceptanceUpload(
        on model: IntercomViewModel,
        authorDevice: GroupDeliveryTestIdentity,
        recipientDevice: GroupDeliveryTestIdentity,
        transfer: InvitationBackgroundTransfer
    ) async throws {
        let author = try recipientDevice.harness(knowing: [authorDevice]).viewModel
        defer {
            model.stopGroupDeliverySync()
            author.stopGroupDeliverySync()
        }
        author.groupDeliveryClient = nil
        model.setRTCTransportRoutes([.webRTC])
        let recording = RecordingBackgroundInvitationTransfer()
        let url = try startBackgroundContactAcceptance(on: model, invitedBy: author, transfer: recording)
        let contact = try #require(model.groupRepository.contactInvitations.first)
        let contactKey = try #require(recording.enqueued.first)
        var contactRequest = try #require(recording.requests[contactKey])
        let receiptID = try #require(contact.receiptID)
        let reply = try JSONSerialization.data(withJSONObject: [
            "id": receiptID.uuidString.lowercased(),
            "expiresAt": Int64((contact.expiresAt * 1000).rounded(.down))
        ])
        model.invitationBackgroundTransfer = transfer
        let payload = try model.groupRepository.contactInvitationPayload(contact.id)
        let address = try InvitationReplyAddress(contactToken: payload.token)
        try await checkBackgroundRedirect(
            request: contactRequest, key: contactKey, reply: reply, transfer: transfer,
            excluded: [
                try authorDevice.principal.userID, try recipientDevice.principal.userID, address.slot,
                receiptID.uuidString.lowercased(), url.absoluteString
            ])
        #expect(model.contactInvitationRecord(contact.id)?.internetAcceptanceSubmitted == nil)
        #expect(model.contactInvitationRecord(contact.id)?.state == .pending)
        try await checkBackgroundUpload(request: &contactRequest, key: contactKey, reply: reply, transfer: transfer)
        #expect(model.contactInvitationRecord(contact.id)?.internetAcceptanceSubmitted == true)
        #expect(model.contactInvitationRecord(contact.id)?.state == .pending)
    }

    private func checkBackgroundUpload(
        request: inout URLRequest, key: InvitationBackgroundUploadID, reply: Data,
        transfer: InvitationBackgroundTransfer
    ) async throws {
        let expectedBody = try #require(request.httpBody)
        let endpoint = try BackgroundUploadLoopback(reply: reply)
        defer { endpoint.listener.cancel() }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { (endpoint.listener.port?.rawValue ?? 0) > 0 }
        let port = try #require(endpoint.listener.port)
        try #require(port.rawValue > 0)
        request.url = URL(string: "http://localhost:\(port.rawValue)/receipt")
        try transfer.enqueue(request, for: key)
        await AppTestSupport.waitUntil(timeout: .seconds(16)) { !transfer.contains(key) }
        let sameBody = endpoint.received.withLock { $0 == expectedBody }
        #expect(sameBody)
        #expect(!transfer.contains(key))
    }

    private func checkBackgroundRedirect(
        request: URLRequest, key: InvitationBackgroundUploadID, reply: Data,
        transfer: InvitationBackgroundTransfer, excluded: [String]
    ) async throws {
        let destination = try BackgroundUploadLoopback(reply: reply)
        defer { destination.listener.cancel() }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { (destination.listener.port?.rawValue ?? 0) > 0 }
        let destinationPort = try #require(destination.listener.port)
        try #require(destinationPort.rawValue > 0)
        let location = try #require(URL(string: "http://127.0.0.1:\(destinationPort.rawValue)/receipt"))
        let redirect = try BackgroundUploadLoopback(reply: Data(), redirectingTo: location)
        defer { redirect.listener.cancel() }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { (redirect.listener.port?.rawValue ?? 0) > 0 }
        let redirectPort = try #require(redirect.listener.port)
        try #require(redirectPort.rawValue > 0)
        var outgoing = request
        outgoing.url = URL(string: "http://localhost:\(redirectPort.rawValue)/receipt")
        try transfer.enqueue(outgoing, for: key)
        await AppTestSupport.waitUntil(timeout: .seconds(16)) { !transfer.contains(key) }
        let originalReceivedBody = redirect.received.withLock { $0 == request.httpBody }
        #expect(originalReceivedBody)
        let body = try #require(destination.received.withLock { $0 })
        let sameBody = body == request.httpBody
        #expect(sameBody)
        #expect(containsOnlySealedInvitation(body, excluding: excluded))
        #expect(!transfer.contains(key))
    }
}

private final class BackgroundUploadLoopback: Sendable {
    let listener: NWListener
    let received = Mutex<Data?>(nil)
    private let queue = DispatchQueue(label: "BackgroundUploadLoopback")
    private let response: Data

    init(reply: Data, redirectingTo location: URL? = nil) throws {
        let close = "Connection: close\r\n\r\n"
        if let location {
            let headers =
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: \(location.absoluteString)\r\n"
                + "Content-Length: 0\r\n" + close
            response = Data(headers.utf8)
        } else {
            let headers =
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + "Content-Length: \(reply.count)\r\n" + close
            response = Data(headers.utf8) + reply
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, complete, error in
            let bytes = buffer + (data ?? Data())
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)),
                let headers = String(bytes: bytes[..<boundary.lowerBound], encoding: .utf8) {
                let length = headers.components(separatedBy: "\r\n").first {
                    $0.lowercased().hasPrefix("content-length:")
                }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
                if let length, bytes.count - boundary.upperBound >= length {
                    received.withLock { $0 = Data(bytes[boundary.upperBound..<(boundary.upperBound + length)]) }
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if error == nil, !complete, bytes.count < 65_536 {
                receive(connection, buffer: bytes)
            } else {
                connection.cancel()
            }
        }
    }
}
#endif
