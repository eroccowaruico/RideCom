import Foundation

/// Records the response to retire after the restored relationships and key references commit.
struct DirectRestoreCompletion: Codable, Equatable {
    let owner: AccountPrincipal
    let deviceID: String
    let sessionBinding: String
    let selectionID: UUID
    let responseID: String
    let expiresAt: Int64

    var isValid: Bool {
        owner.isValid && UUID(uuidString: deviceID)?.uuidString.lowercased() == deviceID
            && InternetAccountClient.notificationUserID(sessionBinding)
            && UUID(uuidString: responseID)?.uuidString.lowercased() == responseID
            && (1...9_007_199_254_740_991).contains(expiresAt)
    }

    func belongs(to identity: VerifiedDeviceIdentity) -> Bool {
        identity.issuer == owner.issuer && identity.userID == owner.userID && identity.deviceID == deviceID
    }

    func canRetire(in identity: VerifiedDeviceIdentity, now: Date) -> Bool {
        belongs(to: identity) && identity.sessionBinding == sessionBinding
            && Double(expiresAt) > now.timeIntervalSince1970 * 1_000
    }
}
