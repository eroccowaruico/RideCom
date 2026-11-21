import Foundation

/// A signed receipt only: no invitation capability, rendezvous key or private key.
/// Parsing never authorizes registration; the account-owned checkpoint and signatures do.
enum ContactReplyURL {
    static func make(_ receipt: DirectInvitationReceipt) throws -> URL {
        let bytes = try JSONEncoder().encode(receipt)
        guard bytes.count <= 8192, receipt.isValid, receipt.invitation?.contactBootstrap == true else {
            throw GroupInviteTokenError.invalidURL
        }
        let value = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard let url = URL(string: "rideintercom://contact-reply?receipt=" + value) else {
            throw GroupInviteTokenError.invalidURL
        }
        return url
    }

    static func decode(_ url: URL) throws -> DirectInvitationReceipt {
        guard url.absoluteString.utf8.count <= 16384, url.scheme == "rideintercom", url.host == "contact-reply",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.path.isEmpty,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.count == 1,
              items[0].name == "receipt", let value = items[0].value, !value.isEmpty,
            value.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    || $0 == 95
            })
        else { throw GroupInviteTokenError.invalidURL }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= 8192 else {
            throw GroupInviteTokenError.invalidURL
        }
        let receipt = try JSONDecoder().decode(DirectInvitationReceipt.self, from: bytes)
        guard receipt.isValid, receipt.invitation?.contactBootstrap == true else {
            throw GroupInviteTokenError.invalidURL
        }
        return receipt
    }
}
