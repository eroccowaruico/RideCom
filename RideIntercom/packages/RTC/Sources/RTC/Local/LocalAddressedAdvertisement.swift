#if !os(watchOS)
import CryptoKit
import Foundation
import Network

/// Advertises offers under the listener's random service name and temporary TLS certificate.
/// An observer without a pair key cannot match two advertisements to the same pair.
struct LocalAddressedAdvertisement {
    private static let fingerprintKey = "f"
    private static let offersKey = "p"
    private static let tagBytes = 16
    private static let fingerprintBytes = 32

    let name: String
    let fingerprint: Data
    private let tags: Set<Data>

    init(name: String, fingerprint: Data, credentials: some Sequence<RTCCredential>) {
        self.name = name
        self.fingerprint = fingerprint
        tags = Set(credentials.map { Self.tag(name: name, fingerprint: fingerprint, credential: $0) })
    }

    init?(name: String, record: NWTXTRecord, maximumOffers: Int) {
        guard UUID(uuidString: name) != nil,
              let fingerprintText = record[Self.fingerprintKey], let fingerprint = Data(base64Encoded: fingerprintText),
              fingerprint.count == Self.fingerprintBytes,
              let offers = record[Self.offersKey], let bytes = Data(base64Encoded: offers),
              (1...maximumOffers * Self.tagBytes).contains(bytes.count), bytes.count.isMultiple(of: Self.tagBytes)
        else { return nil }
        self.name = name
        self.fingerprint = fingerprint
        tags = Set(stride(from: 0, to: bytes.count, by: Self.tagBytes).map { bytes[$0..<$0 + Self.tagBytes] })
    }

    var record: NWTXTRecord {
        let bytes = tags.reduce(into: Data()) { $0.append($1) }
        return .init([Self.fingerprintKey: fingerprint.base64EncodedString(),
                      Self.offersKey: bytes.base64EncodedString()])
    }

    func offers(_ credential: RTCCredential) -> Bool {
        tags.contains(Self.tag(name: name, fingerprint: fingerprint, credential: credential))
    }

    private static func tag(name: String, fingerprint: Data, credential: RTCCredential) -> Data {
        var input = Data("rideintercom.local-addressed-advertisement.v1\0".utf8)
        input.append(contentsOf: name.utf8)
        input.append(0)
        input.append(fingerprint)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: credential.sharedSecret))
        return Data(mac.prefix(tagBytes))
    }
}
#endif
