#if !os(watchOS)
import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A throwaway self-signed TLS identity for one local control listener. The certificate proves
/// nothing by itself: its fingerprint is bound into the group-key handshake, and that handshake is
/// what authenticates the peer. Apple platforms have no API that makes a `SecIdentity` from a key and
/// a certificate, so both are wrapped in a PKCS#12 container in memory and imported from there:
/// nothing is written to the Keychain and nothing is left behind.
/// `SecIdentity` is an immutable system object that may be used from any thread.
struct LocalControlIdentity: @unchecked Sendable {
    enum Failure: Error { case importFailed(OSStatus), invalidCertificate }

    let identity: SecIdentity
    let certificateDER: Data
    /// SHA-256 of the certificate, the value both ends bind into their handshake.
    var fingerprint: Data { Data(SHA256.hash(data: certificateDER)) }

    static func make(now: Date = Date()) throws -> LocalControlIdentity {
        let key = P256.Signing.PrivateKey()
        let certificateDER = try SelfSignedCertificate.make(key: key, now: now)
        // The container never leaves this function; its password protects nothing and only satisfies the format.
        let password = UUID().uuidString
        let container = PKCS12Container.make(privateKeyInfo: key.derRepresentation, certificate: certificateDER, password: password)
        var options: [CFString: Any] = [kSecImportExportPassphrase: password]
        #if os(macOS)
        options[kSecImportToMemoryOnly] = true
        #endif
        var items: CFArray?
        let status = SecPKCS12Import(container as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else { throw Failure.importFailed(status) }
        guard let first = (items as? [[CFString: Any]])?.first, let value = first[kSecImportItemIdentity] else {
            throw Failure.invalidCertificate
        }
        return .init(identity: value as! SecIdentity, certificateDER: certificateDER)
    }
}

/// The smallest PKCS#12 container `SecPKCS12Import` accepts: one key bag, one certificate bag, a password MAC.
enum PKCS12Container {
    static func make(privateKeyInfo: Data, certificate: Data, password: String) -> Data {
        let keyID = DER.set(DER.octetString(Data(SHA256.hash(data: certificate).prefix(20))))
        let attributes = DER.set(DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15]) + keyID)) // localKeyId
        // The import pairs a certificate only with an encrypted (shrouded) key; a plain key bag is ignored.
        let keyBag = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x02]) // pkcs8ShroudedKeyBag
            + DER.tagged(0xA0, encrypted(privateKeyInfo, password: password)) + attributes)
        let certificateBag = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x0A, 0x01, 0x03]) // certBag
            + DER.tagged(0xA0, DER.sequence(
                DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x16, 0x01]) // x509Certificate
                + DER.tagged(0xA0, DER.octetString(certificate))))
            + attributes)
        let safe = DER.sequence(data(DER.sequence(keyBag)) + data(DER.sequence(certificateBag)))
        var salt = Data(count: 8)
        for index in salt.indices { salt[index] = UInt8.random(in: 0...255) }
        let iterations = 2048
        let macKey = SymmetricKey(data: derivedMACKey(password: password, salt: salt, iterations: iterations))
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: safe, using: macKey))
        let macData = DER.sequence(
            DER.sequence(DER.sequence(DER.oid([0x2B, 0x0E, 0x03, 0x02, 0x1A]) + Data([0x05, 0x00])) + DER.octetString(mac)) // SHA-1
            + DER.octetString(salt)
            + DER.integer([UInt8(iterations >> 8), UInt8(iterations & 0xFF)]))
        return DER.sequence(DER.integer([3]) + data(safe) + macData)
    }

    /// PKCS#8 EncryptedPrivateKeyInfo: PBES2 with PBKDF2-HMAC-SHA256 and AES-256-CBC.
    private static func encrypted(_ privateKeyInfo: Data, password: String) -> Data {
        func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }
        let salt = random(16), iv = random(kCCBlockSizeAES128), iterations = 2048
        var key = Data(count: kCCKeySizeAES256)
        let passwordBytes = Array(password.utf8)
        _ = key.withUnsafeMutableBytes { keyBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBufferPointer { passwordPointer in
                    passwordPointer.withMemoryRebound(to: CChar.self) {
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), $0.baseAddress, $0.count,
                                             saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES256)
                    }
                }
            }
        }
        var cipher = Data(count: privateKeyInfo.count + kCCBlockSizeAES128)
        var length = 0
        let capacity = cipher.count
        _ = cipher.withUnsafeMutableBytes { output in
            privateKeyInfo.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, kCCKeySizeAES256, ivBytes.baseAddress,
                                input.baseAddress, privateKeyInfo.count, output.baseAddress, capacity, &length)
                    }
                }
            }
        }
        cipher.count = length
        let derivation = DER.sequence(
            DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]) // PBKDF2
            + DER.sequence(DER.octetString(salt) + DER.integer([UInt8(iterations >> 8), UInt8(iterations & 0xFF)])
                           + DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09]) + Data([0x05, 0x00])))) // hmacWithSHA256
        let scheme = DER.sequence(DER.oid([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A]) + DER.octetString(iv)) // aes256-CBC
        return DER.sequence(
            DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]) + DER.sequence(derivation + scheme)) // PBES2
            + DER.octetString(cipher))
    }

    private static func data(_ content: Data) -> Data {
        DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]) // pkcs7-data
                     + DER.tagged(0xA0, DER.octetString(content)))
    }

    /// RFC 7292 appendix B.2 with SHA-1 and ID 3 (MAC key). One hash block is the whole key.
    private static func derivedMACKey(password: String, salt: Data, iterations: Int) -> Data {
        let block = 64
        var bmp = Data()
        for unit in password.utf16 { bmp.append(UInt8(unit >> 8)); bmp.append(UInt8(unit & 0xFF)) }
        bmp.append(contentsOf: [0, 0])
        func filled(_ source: Data) -> Data {
            guard !source.isEmpty else { return Data() }
            let length = block * ((source.count + block - 1) / block)
            return Data((0..<length).map { source[source.startIndex + $0 % source.count] })
        }
        var digest = Data(Insecure.SHA1.hash(data: Data(repeating: 3, count: block) + filled(salt) + filled(bmp)))
        for _ in 1..<iterations { digest = Data(Insecure.SHA1.hash(data: digest)) }
        return digest
    }
}

/// The smallest X.509 certificate TLS accepts: version 3, one common name, a P-256 key, ECDSA with SHA-256.
enum SelfSignedCertificate {
    static let lifetime: TimeInterval = 2 * 24 * 60 * 60

    static func make(key: P256.Signing.PrivateKey, now: Date) throws -> Data {
        let algorithm = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])) // ecdsa-with-SHA256
        let name = DER.sequence(DER.set(DER.sequence(
            DER.oid([0x55, 0x04, 0x03]) + DER.utf8("RideIntercom Local")))) // commonName
        var serial = [UInt8](repeating: 0, count: 8)
        for index in serial.indices { serial[index] = UInt8.random(in: 0...255) }
        serial[0] = serial[0] & 0x7F | 0x01 // Positive and never a leading zero byte.
        let publicKey = DER.sequence(
            DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])       // id-ecPublicKey
                         + DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])) // prime256v1
            + DER.bitString(key.publicKey.x963Representation))
        let body = DER.sequence(
            DER.tagged(0xA0, DER.integer([2]))
            + DER.integer(serial)
            + algorithm
            + name
            + DER.sequence(DER.utcTime(now.addingTimeInterval(-3600)) + DER.utcTime(now.addingTimeInterval(lifetime)))
            + name
            + publicKey)
        let signature = try key.signature(for: body).derRepresentation
        return DER.sequence(body + algorithm + DER.bitString(signature))
    }
}

enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        if content.count < 0x80 { result.append(UInt8(content.count)) }
        else {
            let bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Array($0).drop { $0 == 0 } }
            result.append(0x80 | UInt8(bytes.count)); result.append(contentsOf: bytes)
        }
        return result + content
    }
    static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
    static func set(_ content: Data) -> Data { tagged(0x31, content) }
    static func oid(_ bytes: [UInt8]) -> Data { tagged(0x06, Data(bytes)) }
    static func integer(_ bytes: [UInt8]) -> Data { tagged(0x02, Data(bytes)) }
    static func utf8(_ text: String) -> Data { tagged(0x0C, Data(text.utf8)) }
    static func octetString(_ bytes: Data) -> Data { tagged(0x04, bytes) }
    static func bitString(_ bytes: Data) -> Data { tagged(0x03, Data([0]) + bytes) }
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }
}
#endif
