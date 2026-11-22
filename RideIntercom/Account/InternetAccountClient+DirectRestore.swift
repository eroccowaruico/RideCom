import Foundation

extension InternetAccountClient {
    private static let restoreDevicePath = "api/direct-call-restore/device"
    private static let restoreRelayPath = "api/direct-call-restore/relay"

    nonisolated private struct RestoreDeviceWrite: Decodable, Sendable {
        let state: String
    }

    nonisolated private struct RestoreRelayInbox: Decodable, Sendable {
        let messages: [DirectCallRestoreRelayPacket.Delivery]
    }

    func submitDirectRestorePacket(_ submission: DirectCallRestoreRelayPacket.Submission,
                                   access: CallNotificationServiceAccess) async throws {
        try validateRestoreAccess(access, expected: submission.sender)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let result: RestoreDeviceWrite = try await sendJSON(
            origin: access.origin, path: Self.restoreRelayPath, method: "PUT",
            body: encoder.encode(submission.payload), token: access.accessToken)
        guard result.state == "queued" || result.state == "retired" else { throw Failure.invalidResponse }
    }

    func directRestoreInbox(access: CallNotificationServiceAccess) async throws
        -> [DirectCallRestoreRelayPacket.Delivery] {
        try validateRestoreAccess(access, expected: access.principal)
        let result: RestoreRelayInbox = try await sendJSON(
            origin: access.origin, path: Self.restoreRelayPath, method: "GET", token: access.accessToken,
            maximumResponseBytes: 256 * 1024)
        let messages = result.messages
        guard messages.count <= 8, Set(messages.map(\.id)).count == messages.count
        else { throw Failure.invalidResponse }
        return messages
    }

    func retireDirectRestorePacket(_ id: String, access: CallNotificationServiceAccess) async throws {
        try validateRestoreAccess(access, expected: access.principal)
        guard UUID(uuidString: id)?.uuidString.lowercased() == id else { throw Failure.rejected }
        let result: RestoreDeviceWrite = try await send(
            origin: access.origin, path: Self.restoreRelayPath, method: "DELETE", body: ["id": id],
            token: access.accessToken)
        guard result.state == "retired" else { throw Failure.invalidResponse }
    }

    func publishDirectRestoreDevice(_ publication: DirectRestoreDevicePublication,
                                    access: CallNotificationServiceAccess) async throws {
        try validateRestoreAccess(access, expected: publication.publisher)
        let result: RestoreDeviceWrite = try await sendJSON(
            origin: access.origin, path: Self.restoreDevicePath, method: "PUT",
            body: JSONEncoder().encode(publication), token: access.accessToken)
        guard result.state == "stored" else { throw Failure.invalidResponse }
    }

    func revokeDirectRestoreDevice(_ withdrawal: DirectRestoreDeviceWithdrawal,
                                   access: CallNotificationServiceAccess) async throws {
        try validateRestoreAccess(access, expected: withdrawal.publisher)
        let result: RestoreDeviceWrite = try await sendJSON(
            origin: access.origin, path: Self.restoreDevicePath, method: "DELETE",
            body: JSONEncoder().encode(withdrawal), token: access.accessToken)
        guard result.state == "revoked" else { throw Failure.invalidResponse }
    }

    @MainActor func fetchDirectRestoreDevice(
        at address: DirectRestoreDeviceAddress, access: CallNotificationServiceAccess
    ) async throws -> DirectRestoreDevicePublication.Delivery? {
        try validateRestoreAccess(access, expected: address.reader)
        do {
            return try await send(origin: access.origin, path: Self.restoreDevicePath,
                                  body: ["owner": address.publisher.userID, "slot": address.slot],
                                  token: access.accessToken)
        } catch Failure.notFound {
            return nil
        }
    }

    private func validateRestoreAccess(_ access: CallNotificationServiceAccess, expected: AccountPrincipal) throws {
        guard access.principal == expected, expected.isValid,
              IdentityEncoding.origin(access.origin) == expected.issuer else { throw Failure.rejected }
        try Self.validateNotificationAccess(access.origin, token: access.accessToken)
    }
}
