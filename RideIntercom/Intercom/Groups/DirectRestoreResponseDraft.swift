import CryptoKit
import Foundation

struct DirectRestoreResponseDraft: Codable, Equatable {
    let requestFingerprint: String
    let credentialReference: UUID
    let responderBinding: String
    let payload: DirectCallRestoreRelaySubmission.Payload

    static func fingerprint(of packet: DirectCallRestoreRelayPacket.Delivery) -> String {
        IdentityEncoding.encode(Data(SHA256.hash(data: Data(packet.packet.utf8))))
    }

    func matches(fingerprint: String, reference: UUID, responder: String, recipient: VerifiedDeviceIdentity) -> Bool {
        requestFingerprint == fingerprint && credentialReference == reference && responderBinding == responder
            && payload.recipient == recipient.userID && payload.deviceID == recipient.deviceID
            && payload.sessionBinding == recipient.sessionBinding
    }
}
