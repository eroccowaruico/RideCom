import Foundation

/// The request and ciphertext need the same lifetime across a restart.
struct DirectRestoreRequestDraft: Codable, Equatable {
    let request: CallRelationshipRestoreRequest
    let payload: DirectCallRestoreRelaySubmission.Payload
    var submitted = false

    func isCurrent(for contactID: UUID, in backup: CallRelationshipBackup,
                   as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date) throws -> Bool {
        guard request.expiresAt > now, let active = signer.identity,
              let origin = try? request.verifiedRequesterIdentity(trust: trust, now: now),
              origin.sessionBinding == active.sessionBinding, origin.deviceID == active.deviceID,
              origin.memberID == active.memberID, origin.deviceKey == active.deviceKey, origin.userID == active.userID,
              payload.recipient == backup.contacts.first(where: { $0.id == contactID })?.principal.userID,
              try backup.matchesDirectRestoreRequest(request, contactID: contactID)
        else { return false }
        return true
    }

    func needsSubmission(at now: Date) -> Bool {
        !submitted && Double(payload.expiresAt) > now.timeIntervalSince1970 * 1_000
    }
}
