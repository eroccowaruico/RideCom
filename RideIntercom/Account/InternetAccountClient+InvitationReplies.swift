import Foundation

extension InternetAccountClient {
    private static let replyMailboxPath = "api/ordinary-group-replies/"
    private static let maximumReplyInboxBytes = 100 * 1024

    nonisolated private struct ReplyMailbox: Encodable {
        let slot: String
        let expiresAt: Int64
    }
    nonisolated private struct ReplySubmission: Encodable {
        let slot: String
        let id: String
        let packet: String
        let owner: String?
        let admission: ContactInvitationReplyAdmission?
        let expiresAt: Int64?
    }
    nonisolated private struct ReplyInbox: Decodable, Sendable { let acceptances: [InvitationReplyPacket]? }
    nonisolated private struct ReplyReceipt: Decodable, Sendable { let receipt: InvitationReplyPacket? }
    nonisolated private struct ReplyWritten: Decodable, Sendable {}

    func openInvitationReplyMailbox(_ address: InvitationReplyAddress, access: CallNotificationServiceAccess) async throws {
        let body = ReplyMailbox(slot: address.slot, expiresAt: address.expiresAt)
        let _: ReplyWritten = try await sendJSON(origin: access.origin, path: Self.replyMailboxPath + "open",
            method: "PUT", body: JSONEncoder().encode(body), token: access.accessToken)
    }

    func submitInvitationAcceptance(_ packet: InvitationReplyPacket, address: InvitationReplyAddress,
                                    owner: AccountPrincipal, access: CallNotificationServiceAccess,
                                    admission: ContactInvitationReplyAdmission? = nil) async throws {
        guard owner.isValid, owner.issuer == access.principal.issuer,
              admission.map({ $0.owner == owner && $0.expiresAt == address.expiresAt }) ?? true else { throw Failure.rejected }
        try await writeInvitationReply(packet, action: "acceptance", address: address, owner: owner.userID, access: access,
                                       admission: admission)
    }

    static func backgroundContactAcceptanceRequest(_ packet: InvitationReplyPacket, address: InvitationReplyAddress,
                                                   owner: AccountPrincipal, access: CallNotificationServiceAccess,
                                                   signer: DeviceIdentitySigner, admission: ContactInvitationReplyAdmission?, now: Date) throws -> URLRequest? {
        guard owner.isValid, owner != access.principal, owner.issuer == access.principal.issuer,
              admission.map({ $0.owner == owner && $0.expiresAt == address.expiresAt }) ?? true else { return nil }
        let body = ReplySubmission(slot: address.slot, id: packet.id.uuidString.lowercased(), packet: packet.packet,
                                   owner: owner.userID, admission: admission, expiresAt: address.expiresAt)
        return try backgroundSubmissionRequest(body, path: replyMailboxPath + "background-acceptance",
                                               purpose: .submitBackgroundContactInvitationAcceptance, access: access, signer: signer, now: now)
    }

    func invitationReplyInbox(_ address: InvitationReplyAddress, access: CallNotificationServiceAccess) async throws -> [InvitationReplyPacket] {
        let body = try JSONEncoder().encode(["slot": address.slot])
        let response: ReplyInbox = try await sendJSON(origin: access.origin, path: Self.replyMailboxPath + "inbox",
            body: body, token: access.accessToken, acceptsMissing: true, maximumResponseBytes: Self.maximumReplyInboxBytes)
        let packets = response.acceptances ?? []
        guard packets.count <= 8, Set(packets.map(\.id)).count == packets.count else { throw Failure.invalidResponse }
        return packets
    }

    func acknowledgeInvitationReply(_ packet: InvitationReplyPacket, address: InvitationReplyAddress,
                                       access: CallNotificationServiceAccess) async throws {
        try await writeInvitationReply(packet, action: "acknowledgement", address: address, owner: nil, access: access)
    }

    func invitationReplyReceipt(id: UUID, address: InvitationReplyAddress, owner: AccountPrincipal,
                                   access: CallNotificationServiceAccess) async throws -> InvitationReplyPacket? {
        guard owner.isValid, owner.issuer == access.principal.issuer else { throw Failure.rejected }
        let body = ["slot": address.slot, "id": id.uuidString.lowercased(), "owner": owner.userID]
        let response: ReplyReceipt = try await sendJSON(origin: access.origin, path: Self.replyMailboxPath + "receipt",
            body: JSONEncoder().encode(body), token: access.accessToken, acceptsMissing: true)
        guard (response.receipt?.id ?? id) == id else { throw Failure.invalidResponse }
        return response.receipt
    }

    private func writeInvitationReply(_ packet: InvitationReplyPacket, action: String, address: InvitationReplyAddress,
                                      owner: String?, access: CallNotificationServiceAccess,
                                      admission: ContactInvitationReplyAdmission? = nil) async throws {
        let body = ReplySubmission(slot: address.slot, id: packet.id.uuidString.lowercased(), packet: packet.packet, owner: owner,
                                   admission: admission, expiresAt: nil)
        let _: ReplyWritten = try await sendJSON(origin: access.origin, path: Self.replyMailboxPath + action, method: "PUT",
            body: JSONEncoder().encode(body), token: access.accessToken)
    }
}
