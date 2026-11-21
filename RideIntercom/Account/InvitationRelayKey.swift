import CryptoKit
import Foundation

nonisolated struct InvitationRelayKey: Decodable, Sendable {
    let kid: String
    private enum CodingKeys: String, CodingKey {
        case kid, expiresAt
        case publicCoordinate = "x"
    }

    let publicCoordinate: String
    let expiresAt: TimeInterval

    func belongsToCertificate(issuedAt: TimeInterval) -> Bool {
        let period = (issuedAt / 2_592_000).rounded(.down)
        guard let number = Int64(exactly: period),
              let coordinate = IdentityEncoding.decode(publicCoordinate), coordinate.count == 32 else { return false }
        return kid == "v1-\(number)" && expiresAt == (period + 2) * 2_592_000
    }

    func seal(_ signedRequest: Data, now: Date) throws -> String? {
        guard expiresAt > now.timeIntervalSince1970,
            let coordinate = IdentityEncoding.decode(publicCoordinate)
        else { return nil }
        let worker = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: coordinate)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: worker)
        let algorithm = Data("A256GCM".utf8)
        // RFC 7518 Concat KDF for the direct ECDH-ES mode, with empty party info and a 256-bit content key.
        var input = Self.uint32(1)
        secret.withUnsafeBytes { input.append(contentsOf: $0) }
        input.append(Self.uint32(UInt32(algorithm.count)))
        input.append(algorithm)
        input.append(Self.uint32(0) + Self.uint32(0) + Self.uint32(256))
        let key = SymmetricKey(data: SHA256.hash(data: input))
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "ECDH-ES", "enc": "A256GCM", "kid": kid,
            "epk": ["kty": "OKP", "crv": "X25519", "x": IdentityEncoding.encode(ephemeral.publicKey.rawRepresentation)]
        ], options: [.sortedKeys])
        let protected = IdentityEncoding.encode(header)
        let sealed = try AES.GCM.seal(signedRequest, using: key, authenticating: Data(protected.utf8))
        return [protected, "", IdentityEncoding.encode(Data(sealed.nonce)), IdentityEncoding.encode(sealed.ciphertext),
                IdentityEncoding.encode(sealed.tag)].joined(separator: ".")
    }

    private static func uint32(_ number: UInt32) -> Data {
        var bigEndian = number.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
