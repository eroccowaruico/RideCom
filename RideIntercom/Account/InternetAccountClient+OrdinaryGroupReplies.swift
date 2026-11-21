import Foundation

extension InternetAccountClient {
    private static let ordinaryReplyPath = "api/ordinary-group-replies/"
    private static let maximumOrdinaryReplyInboxBytes = 100 * 1024

    nonisolated private struct ReplyMailbox: Encodable {
        let slot: String
        let expiresAt: Int64
    }
    nonisolated private struct ReplySubmission: Encodable {
        let slot: String
        let id: String
        let packet: String
        let owner: String?
    }
    nonisolated private struct ReplyInbox: Decodable, Sendable { let acceptances: [OrdinaryGroupReplyPacket]? }
    nonisolated private struct ReplyReceipt: Decodable, Sendable { let receipt: OrdinaryGroupReplyPacket? }
    nonisolated private struct ReplyWritten: Decodable, Sendable {}

    func openOrdinaryGroupReply(_ address: OrdinaryGroupReplyAddress, access: CallNotificationServiceAccess) async throws {
        let body = ReplyMailbox(slot: address.slot, expiresAt: address.expiresAt)
        let _: ReplyWritten = try await sendJSON(origin: access.origin, path: Self.ordinaryReplyPath + "open",
            method: "PUT", body: JSONEncoder().encode(body), token: access.accessToken)
    }

    func submitOrdinaryGroupAcceptance(_ packet: OrdinaryGroupReplyPacket, address: OrdinaryGroupReplyAddress,
                                       owner: AccountPrincipal, access: CallNotificationServiceAccess) async throws {
        guard owner.isValid, owner.issuer == access.principal.issuer else { throw Failure.rejected }
        try await writeOrdinaryGroupReply(packet, action: "acceptance", address: address, owner: owner.userID, access: access)
    }

    func ordinaryGroupReplyInbox(_ address: OrdinaryGroupReplyAddress, access: CallNotificationServiceAccess) async throws -> [OrdinaryGroupReplyPacket] {
        let body = try JSONEncoder().encode(["slot": address.slot])
        let response: ReplyInbox = try await sendJSON(origin: access.origin, path: Self.ordinaryReplyPath + "inbox",
            body: body, token: access.accessToken, acceptsMissing: true, maximumResponseBytes: Self.maximumOrdinaryReplyInboxBytes)
        let packets = response.acceptances ?? []
        guard packets.count <= 8, Set(packets.map(\.id)).count == packets.count else { throw Failure.invalidResponse }
        return packets
    }

    func acknowledgeOrdinaryGroupReply(_ packet: OrdinaryGroupReplyPacket, address: OrdinaryGroupReplyAddress,
                                       access: CallNotificationServiceAccess) async throws {
        try await writeOrdinaryGroupReply(packet, action: "acknowledgement", address: address, owner: nil, access: access)
    }

    func ordinaryGroupReplyReceipt(id: UUID, address: OrdinaryGroupReplyAddress, owner: AccountPrincipal,
                                   access: CallNotificationServiceAccess) async throws -> OrdinaryGroupReplyPacket? {
        guard owner.isValid, owner.issuer == access.principal.issuer else { throw Failure.rejected }
        let body = ["slot": address.slot, "id": id.uuidString.lowercased(), "owner": owner.userID]
        let response: ReplyReceipt = try await sendJSON(origin: access.origin, path: Self.ordinaryReplyPath + "receipt",
            body: JSONEncoder().encode(body), token: access.accessToken, acceptsMissing: true)
        guard (response.receipt?.id ?? id) == id else { throw Failure.invalidResponse }
        return response.receipt
    }

    private func writeOrdinaryGroupReply(_ packet: OrdinaryGroupReplyPacket, action: String, address: OrdinaryGroupReplyAddress,
                                         owner: String?, access: CallNotificationServiceAccess) async throws {
        let body = ReplySubmission(slot: address.slot, id: packet.id.uuidString.lowercased(), packet: packet.packet, owner: owner)
        let _: ReplyWritten = try await sendJSON(origin: access.origin, path: Self.ordinaryReplyPath + action, method: "PUT",
            body: JSONEncoder().encode(body), token: access.accessToken)
    }
}
