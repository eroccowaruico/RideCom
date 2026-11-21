import Foundation

nonisolated struct CallNotificationGrant: Codable, Equatable, Sendable {
    let grantID: UUID
    let capability: String
    var isValid: Bool { !capability.isEmpty && capability.utf8.count <= 4096 }

    /// A rejection filter for an already authenticated contact exchange. Decoding
    /// these claims does not establish issuer trust; the server verifies the JWT.
    func isAddressed(to recipient: AccountPrincipal, from sender: AccountPrincipal, audience: String = "rideintercom-call-notification") -> Bool {
        let parts = capability.split(separator: ".", omittingEmptySubsequences: false)
        guard isValid, parts.count == 3, recipient.issuer == sender.issuer,
              let data = IdentityEncoding.decode(String(parts[1])),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              claims["iss"] as? String == recipient.issuer, claims["aud"] as? String == audience,
              claims["recipient"] as? String == recipient.userID, claims["sub"] as? String == sender.userID,
              let id = claims["jti"] as? String, UUID(uuidString: id) == grantID else { return false }
        return true
    }
}

nonisolated struct CallNotificationReply: Codable, Equatable, Sendable {
    let requestID: UUID
    let expiresAt: Double // Server milliseconds since 1970, never a new local lifetime.
    let status: CallNotificationStatus
    var senderUserID: String?
    func isLive(at now: Date) -> Bool {
        expiresAt.isFinite && expiresAt > now.timeIntervalSince1970 * 1000 && status != .cancelled
    }
}

extension InternetAccountClient {
    nonisolated private struct NotificationAcknowledgement: Decodable, Sendable { var registered: Bool? }

    func registerNotificationDevice(origin: URL, token: String, deviceToken: Data, environment: String, topic: String) async throws {
        try validateNotificationAccess(origin, token: token)
        guard !deviceToken.isEmpty, deviceToken.count <= 2048, ["sandbox", "production"].contains(environment), !topic.isEmpty else { throw Failure.invalidResponse }
        let result: NotificationAcknowledgement = try await send(origin: origin, path: "api/notifications/device", method: "PUT",
            body: ["token": deviceToken.map { String(format: "%02x", $0) }.joined(), "environment": environment, "topic": topic], token: token)
        guard result.registered == true else { throw Failure.invalidResponse }
    }
    func removeNotificationDevice(origin: URL, token: String) async throws {
        try validateNotificationAccess(origin, token: token)
        let _: NotificationAcknowledgement = try await send(origin: origin, path: "api/notifications/device", method: "DELETE", token: token)
    }
    func issueNotificationGrant(origin: URL, token: String, senderUserID: String) async throws -> CallNotificationGrant {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(senderUserID) else { throw Failure.invalidResponse }
        let result: CallNotificationGrant = try await send(origin: origin, path: "api/notifications/grants", body: ["senderUserID": senderUserID], token: token)
        guard result.isValid else { throw Failure.invalidResponse }
        return result
    }
    func issueGroupInvitationGrant(origin: URL, token: String, senderUserID: String) async throws -> CallNotificationGrant {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(senderUserID) else { throw Failure.invalidResponse }
        let value: CallNotificationGrant = try await send(origin: origin, path: "api/notifications/group-invitations/grants",
            body: ["senderUserID": senderUserID], token: token)
        guard value.isValid else { throw Failure.invalidResponse }
        return value
    }
    func revokeNotificationGrant(origin: URL, token: String, grantID: UUID? = nil) async throws {
        try validateNotificationAccess(origin, token: token)
        let path = "api/notifications/grants" + (grantID.map { "/" + $0.uuidString.lowercased() } ?? "")
        let _: NotificationAcknowledgement = try await send(origin: origin, path: path, method: "DELETE", token: token)
    }
    func sendCallNotification(origin: URL, token: String, capability: String, requestID: UUID) async throws -> CallNotificationReply {
        try validateNotificationAccess(origin, token: token)
        guard !capability.isEmpty, capability.utf8.count <= 4096 else { throw Failure.invalidResponse }
        let result: CallNotificationReply = try await send(origin: origin, path: "api/notifications/calls",
            body: ["capability": capability, "requestID": requestID.uuidString.lowercased()], token: token)
        guard result.requestID == requestID, result.expiresAt.isFinite, result.expiresAt > 0 else { throw Failure.invalidResponse }
        return result
    }
    func readCallNotification(origin: URL, token: String, recipientUserID: String, requestID: UUID) async throws -> CallNotificationReply {
        try validateNotificationAccess(origin, token: token)
        guard Self.notificationUserID(recipientUserID) else { throw Failure.invalidResponse }
        let result: CallNotificationReply = try await send(origin: origin,
            path: "api/notifications/calls/\(recipientUserID)/\(requestID.uuidString.lowercased())", method: "GET", token: token)
        guard result.requestID == requestID, result.expiresAt.isFinite, result.expiresAt > 0,
              result.senderUserID.map(Self.notificationUserID) == true else { throw Failure.invalidResponse }
        return result
    }
    private func validateNotificationAccess(_ origin: URL, token: String) throws {
        _ = try Self.origin(origin.absoluteString)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "ri1", Self.notificationUserID(parts[1]), UUID(uuidString: parts[2]) != nil,
              Self.notificationUserID(parts[3]) else { throw Failure.rejected }
    }
    nonisolated static func notificationUserID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}


nonisolated struct GroupDeliveryReply: Decodable, Sendable {
    let requestID: UUID
    let expiresAt: Double
    let status: GroupDeliveryRecord.State

    func matches(id: UUID, expiresAt: TimeInterval) -> Bool {
        requestID == id && self.expiresAt.isFinite && abs(self.expiresAt - expiresAt * 1000) < 1
    }
}
nonisolated struct GroupDeliveryItem: Decodable, Sendable {
    let requestID: UUID
    let senderUserID: String
    let recipientKey: String
    let expiresAt: Double
    let envelope: String
    let sourceRequestID: UUID?
}
extension InternetAccountClient {
    nonisolated private struct GroupInbox: Decodable, Sendable { let delivery: GroupDeliveryItem? }
    nonisolated private struct AdditionalDeviceInvitations: Decodable, Sendable { let requestIDs: [UUID]? }
    nonisolated private struct AdditionalDevices: Decodable, Sendable { let devices: [GroupInvitationAddress]? }
    nonisolated private struct GroupAcknowledgement: Decodable, Sendable {
        let status: GroupDeliveryRecord.State
    }
    nonisolated private struct RedeliveryAcknowledgement: Decodable, Sendable {}
    nonisolated private struct GroupSubmission: Encodable, Sendable {
        let capability: String; let requestID: String; let noticeID: String; let expiresAt: Double; let recipientKey: String; let envelope: String
        let sourceRequestID: String?
    }
    func sendGroupInvitation(_ envelope: GroupInvitationEnvelope, noticeID: UUID, capability: String, access: CallNotificationServiceAccess) async throws -> GroupDeliveryReply {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= 16384, !capability.isEmpty, capability.utf8.count <= 4096 else { throw Failure.invalidResponse }
        let body = GroupSubmission(capability: capability, requestID: envelope.id.uuidString.lowercased(), noticeID: noticeID.uuidString.lowercased(),
            expiresAt: envelope.expiresAt * 1000, recipientKey: envelope.recipientKey, envelope: data.base64EncodedString(),
            sourceRequestID: envelope.sourceRequestID?.uuidString.lowercased())
        let reply: GroupDeliveryReply = try await sendJSON(origin: access.origin, path: "api/notifications/group-invitations", body: JSONEncoder().encode(body), token: access.accessToken)
        guard reply.matches(id: envelope.id, expiresAt: envelope.expiresAt),
              [.queued, .received, .cancelled].contains(reply.status) else { throw Failure.invalidResponse }
        return reply
    }

    func expiredGroupInvitationOutcome(for record: GroupDeliveryRecord,
                                       access: CallNotificationServiceAccess) async throws -> GroupDeliveryRecord.State? {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard record.recipient.isValid, record.recipient.issuer == access.principal.issuer else { throw Failure.invalidResponse }
        do {
            let path = "api/notifications/group-invitations/\(record.recipient.userID)/\(record.id.uuidString.lowercased())"
            let reply: GroupDeliveryReply = try await sendJSON(origin: access.origin, path: path, method: "GET", token: access.accessToken)
            guard reply.matches(id: record.id, expiresAt: record.expiresAt), [.received, .cancelled].contains(reply.status)
            else { throw Failure.invalidResponse }
            return reply.status
        } catch Failure.notFound { return nil }
    }
    func nextGroupInvitation(recipientKey: String, access: CallNotificationServiceAccess) async throws -> GroupDeliveryItem? {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard DeviceIdentityProof.isValidPublicKey(recipientKey) else { throw Failure.invalidResponse }
        let result: GroupInbox = try await sendJSON(origin: access.origin, path: "api/notifications/group-invitations", method: "GET",
            token: access.accessToken, query: [.init(name: "recipientKey", value: recipientKey)])
        if let value = result.delivery {
            guard value.recipientKey == recipientKey, Self.notificationUserID(value.senderUserID), value.expiresAt.isFinite,
                  value.expiresAt > 0, value.envelope.utf8.count <= 21848 else { throw Failure.invalidResponse }
        }
        return result.delivery
    }
    func invitationsForAdditionalDevice(recipientKey: String, access: CallNotificationServiceAccess) async throws -> [UUID] {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard DeviceIdentityProof.isValidPublicKey(recipientKey) else { throw Failure.invalidResponse }
        let result: AdditionalDeviceInvitations = try await sendJSON(origin: access.origin,
            path: "api/notifications/group-invitations/additional-devices", method: "GET", token: access.accessToken,
            query: [.init(name: "recipientKey", value: recipientKey)], acceptsMissing: true)
        let ids = result.requestIDs ?? []
        guard ids.count <= 64, Set(ids).count == ids.count else { throw Failure.invalidResponse }
        return ids
    }

    func additionalDevices(for record: GroupDeliveryRecord, access: CallNotificationServiceAccess) async throws -> [GroupInvitationAddress] {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard record.recipient.isValid, record.recipient.issuer == access.principal.issuer else { throw Failure.invalidResponse }
        let result: AdditionalDevices = try await sendJSON(origin: access.origin,
            path: "api/notifications/group-invitations/\(record.recipient.userID)/\(record.id.uuidString.lowercased())/additional-devices",
            method: "GET", token: access.accessToken, acceptsMissing: true)
        let devices = result.devices ?? []
        guard devices.count <= 8 else { throw Failure.invalidResponse }
        return devices
    }

    func requestGroupInvitationForAdditionalDevice(_ id: UUID, signer: DeviceIdentitySigner,
                                                   access: CallNotificationServiceAccess) async throws {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard access.principal.isValid, signer.principal == access.principal else { throw Failure.invalidResponse }
        let requestID = id.uuidString.lowercased()
        let proof = try signer.sign(Data(requestID.utf8), purpose: .requestGroupInvitationRedelivery)
        let _: RedeliveryAcknowledgement = try await sendJSON(origin: access.origin,
            path: "api/notifications/group-invitations/\(access.principal.userID)/\(requestID)/additional-devices",
            body: JSONEncoder().encode(proof), token: access.accessToken, acceptsMissing: true)
    }

    @discardableResult
    func finishGroupInvitation(recipient: AccountPrincipal, id: UUID, discard: Bool = false,
                               access: CallNotificationServiceAccess) async throws -> GroupDeliveryRecord.State? {
        try validateNotificationAccess(access.origin, token: access.accessToken)
        guard recipient.isValid, recipient.issuer == access.principal.issuer else { throw Failure.invalidResponse }
        do {
            let reply: GroupAcknowledgement = try await sendJSON(origin: access.origin,
                path: "api/notifications/group-invitations/\(recipient.userID)/\(id.uuidString.lowercased())", method: "DELETE", token: access.accessToken,
                query: discard ? [.init(name: "discard", value: "1")] : [])
            guard reply.status == .received || reply.status == .cancelled else { throw Failure.invalidResponse }
            return reply.status
        } catch Failure.notFound {
            return nil
        }
    }

    func acknowledgeGroupInvitation(_ id: UUID, access: CallNotificationServiceAccess) async throws -> GroupDeliveryRecord.State? {
        try await finishGroupInvitation(recipient: access.principal, id: id, access: access)
    }
}
