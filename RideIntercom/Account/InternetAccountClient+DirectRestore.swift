import Foundation

extension InternetAccountClient {
    private static let restoreDevicePath = "api/direct-call-restore/device"

    nonisolated private struct RestoreDeviceWrite: Decodable, Sendable {
        let state: String
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
