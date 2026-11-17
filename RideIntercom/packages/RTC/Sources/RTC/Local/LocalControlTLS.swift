#if !os(watchOS)
import CryptoKit
import Foundation
import Network
import Security

/// QUIC parameters of the local control connection. Both ends present a throwaway self-signed
/// certificate (mutual TLS) and accept whatever certificate the other presents: TLS only gives the two
/// ends an encrypted channel and each other's certificate fingerprint. Who the peer is gets decided
/// afterwards, by the group-key handshake that binds both fingerprints.
enum LocalControlTLS {
    static let applicationProtocol = "ride-control"

    /// - Parameter peerFingerprint: called once per connection with the SHA-256 of the peer's certificate,
    ///   before the connection becomes ready.
    static func parameters(identity: LocalControlIdentity,
                           peerFingerprint: @escaping @Sendable (Data) -> Void) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
        let security = quic.securityProtocolOptions
        if let local = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(security, local)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            let evaluated = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(evaluated) as? [SecCertificate], let leaf = chain.first else {
                complete(false); return
            }
            peerFingerprint(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data)))
            complete(true)
        }, verificationQueue)
        let parameters = NWParameters(quic: quic)
        // The same radio as the audio datagrams: peer-to-peer Wi-Fi, never cellular.
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private static let verificationQueue = DispatchQueue(label: "RideIntercom.LocalControlTLS.verify")
}
#endif
