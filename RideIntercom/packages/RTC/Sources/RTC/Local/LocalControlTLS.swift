#if !os(watchOS)
import Foundation
import Network
import Security

/// QUIC parameters of the local control connection. Both ends present a throwaway self-signed
/// certificate (mutual TLS) and accept whatever certificate the other presents: TLS only gives the two
/// ends an encrypted channel and each other's certificate. Who the peer is gets decided afterwards, by
/// the group-key handshake that binds both certificate fingerprints (`LocalControlLink`).
enum LocalControlTLS {
    static let applicationProtocol = "ride-control"

    static func parameters(identity: LocalControlIdentity) -> NWParameters {
        let quic = NWProtocolQUIC.Options(alpn: [applicationProtocol])
        let security = quic.securityProtocolOptions
        if let local = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(security, local)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        // Any certificate is accepted here. `LocalControlLink` reads it back from the connection and the
        // handshake decides.
        sec_protocol_options_set_verify_block(security, { _, _, complete in complete(true) }, verificationQueue)
        let parameters = NWParameters(quic: quic)
        // The same radio as the audio datagrams: peer-to-peer Wi-Fi, never cellular.
        parameters.includePeerToPeer = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    private static let verificationQueue = DispatchQueue(label: "RideIntercom.LocalControlTLS.verify")
}
#endif
