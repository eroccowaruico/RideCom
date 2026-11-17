import CryptoKit
import Foundation
import Security
import Testing
@testable import RTC

struct LocalControlIdentityTests {
    @Test func theCertificateIsOneTheSystemParsesAndItsKeySignedIt() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let der = try SelfSignedCertificate.make(key: key, now: now)
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "RideIntercom Local")
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        let exported = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        #expect(exported == key.publicKey.x963Representation)

        // Self-signed: it chains to itself and to nothing else, inside its own validity only.
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let evaluated = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(evaluated, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(evaluated, now as CFDate) == errSecSuccess)
        #expect(SecTrustEvaluateWithError(evaluated, nil))
        #expect(SecTrustSetVerifyDate(evaluated, now.addingTimeInterval(SelfSignedCertificate.lifetime + 60) as CFDate) == errSecSuccess)
        #expect(!SecTrustEvaluateWithError(evaluated, nil))
    }

    @Test func everyCertificateDiffers() throws {
        let key = P256.Signing.PrivateKey(), now = Date()
        #expect(try SelfSignedCertificate.make(key: key, now: now) != SelfSignedCertificate.make(key: key, now: now))
    }

    @Test func anIdentityCarriesItsCertificateAndTheKeyThatSignedIt() throws {
        let made = try LocalControlIdentity.make()
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(made.identity, &certificate) == errSecSuccess)
        #expect(certificate.map { SecCertificateCopyData($0) as Data } == made.certificateDER)
        #expect(made.fingerprint == Data(SHA256.hash(data: made.certificateDER)))
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(made.identity, &key) == errSecSuccess)
        let privateKey = try #require(key)
        let message = Data("bound".utf8)
        let signature = try #require(SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil) as Data?)
        let publicKey = try #require(certificate.flatMap { SecCertificateCopyKey($0) })
        #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature as CFData, nil))
    }
}
