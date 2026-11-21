import Foundation

nonisolated struct ContactDeletionWorkerPacket: Decodable, Sendable {
    let id: UUID
    let expiresAt: Int64
    let packet: String

    func matches(_ target: ContactDeletionNotice.Target) -> Bool {
        target.id == id && (try? ContactDeletionRelayPacket.expiry(target)) == expiresAt
    }
}

nonisolated enum ContactDeletionWorkerState: String, Decodable, Sendable {
    case pending, received, retired
}

extension InternetAccountClient {
    nonisolated private struct DeletionWrite: Encodable {
        let slot: String
        let id: String
        let expiresAt: Int64
        let recipient: String?
        let recipientKey: String?
        let packet: String?
    }
    nonisolated private struct DeletionRead: Encodable {
        let owner: String
        let slot: String
        let proof: DeviceIdentityProof?
    }
    nonisolated private struct DeletionAcknowledgement: Encodable {
        let owner: String
        let slot: String
        let id: String
        let packet: String
        let proof: DeviceIdentityProof
    }
    nonisolated private struct DeletionInbox: Decodable, Sendable {
        let deletion: ContactDeletionWorkerPacket?
        let receipt: ContactDeletionWorkerPacket?
    }
    nonisolated private struct DeletionResponse: Decodable, Sendable {
        let state: ContactDeletionWorkerState?
    }

    func writeContactDeletion(_ record: ContactDeletionPublication, access: CallNotificationServiceAccess)
        async throws -> ContactDeletionWorkerState {
        guard record.sender == access.principal else { throw Failure.rejected }
        let body = DeletionWrite(slot: record.slot, id: record.id.uuidString.lowercased(), expiresAt: record.expiresAt,
            recipient: record.payload?.recipient.userID, recipientKey: record.payload?.recipientKey,
            packet: record.payload?.packet)
        let response: DeletionResponse = try await sendJSON(origin: access.origin, path: "api/contact-deletions",
            method: record.payload == nil ? "DELETE" : "PUT", body: JSONEncoder().encode(body),
            token: access.accessToken)
        guard let state = response.state, record.payload != nil || state == .retired else {
            throw Failure.invalidResponse
        }
        return state
    }

    func readContactDeletion(owner: AccountPrincipal, slot: String, access: CallNotificationServiceAccess,
                             recipient: DeviceIdentitySigner? = nil) async throws -> ContactDeletionWorkerPacket? {
        guard owner.issuer == access.principal.issuer, (recipient == nil) == (owner == access.principal),
              recipient == nil || recipient?.principal == access.principal else { throw Failure.rejected }
        let proof = try recipient?.sign(Self.deletionProofPayload([owner.userID, slot]), purpose: .readContactDeletion)
        let body = DeletionRead(owner: owner.userID, slot: slot, proof: proof)
        let response: DeletionInbox = try await sendJSON(origin: access.origin, path: "api/contact-deletions/read",
            body: JSONEncoder().encode(body), token: access.accessToken, acceptsMissing: true)
        return recipient == nil ? response.receipt : response.deletion
    }

    func acknowledgeRelayedContactDeletion(_ record: ContactDeletionRelayReceipt, signer: DeviceIdentitySigner,
                                           access: CallNotificationServiceAccess) async throws -> Bool {
        guard record.recipient == access.principal, signer.principal == access.principal else { throw Failure.rejected }
        let id = record.id.uuidString.lowercased()
        let proof = try signer.sign(Self.deletionProofPayload([record.owner.userID, record.slot, id, record.packet]),
                                    purpose: .acknowledgeContactDeletionRelay)
        let body = DeletionAcknowledgement(
            owner: record.owner.userID, slot: record.slot, id: id, packet: record.packet, proof: proof)
        let response: DeletionResponse = try await sendJSON(
            origin: access.origin, path: "api/contact-deletions/receipt",
            method: "PUT", body: JSONEncoder().encode(body), token: access.accessToken, acceptsMissing: true)
        return response.state == .received
    }

    private static func deletionProofPayload(_ values: [String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(values)
    }
}
