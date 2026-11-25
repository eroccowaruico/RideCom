import Foundation

extension CloudflareRealtimeSignalingClient {
    enum Failure: Error, LocalizedError {
        case invalidConfiguration, invalidResponse, accountInUse, deviceCredentialRejected
        case peerSnapshotChanged, servicePaused, http(Int)

        init(httpStatus: Int) {
            self = httpStatus == 401 ? .deviceCredentialRejected : .http(httpStatus)
        }

        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .invalidConfiguration: "A secure Worker URL and device token are required"
            case .invalidResponse: "Invalid Cloudflare response"
            case .accountInUse:
                "This account already has an Internet call. End the existing call, then try again. "
                    + "If the other device lost its connection, wait for that call to expire."
            case .peerSnapshotChanged: "Cloudflare peer snapshot changed"
            case .servicePaused: String(localized: "Internet calling is paused.")
            case .deviceCredentialRejected: "Device credential rejected"
            case .http(let code): "Cloudflare Worker rejected request (HTTP \(code))"
            }
        }
    }
}
