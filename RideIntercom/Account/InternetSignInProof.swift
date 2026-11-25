import AuthenticationServices
import CryptoKit
import Foundation

/// A short-lived proof from Apple authentication, held only in memory.
nonisolated struct InternetSignInProof: Sendable {
    let id = UUID()
    let identityToken: Data
    let expiresAt: Date
    private let key: P256.Signing.PrivateKey

    init?(identityToken: Data, key: P256.Signing.PrivateKey) {
        guard identityToken.count <= 16384, let token = String(data: identityToken, encoding: .utf8) else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = IdentityEncoding.decode(String(parts[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload), claims.exp.isFinite
        else { return nil }
        expiresAt = Date(timeIntervalSince1970: claims.exp)
        guard expiresAt > Date() else { return nil }
        self.identityToken = identityToken
        self.key = key
    }

    static func nonce(for key: P256.Signing.PrivateKey) -> String {
        let publicKey = IdentityEncoding.encode(key.publicKey.x963Representation)
        return digest(Data("ridecom.apple-sign-in-key.v1\n\(publicKey)".utf8))
    }

    func sign(_ challenge: InternetAccountChallenge, deviceKey: String) throws -> Signature {
        let message = [
            "ridecom.apple-enrollment.v1", challenge.deviceID, challenge.nonce, Self.digest(identityToken), deviceKey
        ].joined(separator: "\n")
        let signature = try key.signature(for: Data(message.utf8))
        return Signature(publicKey: IdentityEncoding.encode(key.publicKey.x963Representation),
                         signature: IdentityEncoding.encode(signature.rawRepresentation), deviceKey: deviceKey)
    }

    struct Signature: Encodable {
        let publicKey: String
        let signature: String
        let deviceKey: String
    }

    private struct Claims: Decodable { let exp: Double }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct AppleEnrollmentConfirmation {
    private let userID: String
    private let state = UUID().uuidString
    private let key = P256.Signing.PrivateKey()

    init(request: ASAuthorizationAppleIDRequest, userID: String) {
        self.userID = userID
        request.requestedScopes = []
        request.user = userID
        request.state = state
        request.nonce = InternetSignInProof.nonce(for: key)
    }

    func proof(userID: String, state: String?, identityToken: Data?) -> InternetSignInProof? {
        guard userID == self.userID, state == self.state, let identityToken else { return nil }
        return InternetSignInProof(identityToken: identityToken, key: key)
    }
}
