import { fromDER } from 'asn1js'
import { decode, decodeFirst } from 'cborg'
import { base64url } from 'jose'
import { BasicConstraints, Certificate, CertificateChainValidationEngine, CryptoEngine } from 'pkijs'
import { type AppAttestLaunch, appAttestCBOR, appAttestLaunchMatches, appAttestNonce, sha256 } from './AppAttestData'

// Apple App Attestation Root CA, https://www.apple.com/certificateauthority/private/
const appleRoot = `
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
`.replace(/\s/g, '')
const macAccessPolicy = 'MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB'
const encoder = new TextEncoder()
const decodeBase64 = (text: string) => Uint8Array.from(atob(text), char => char.charCodeAt(0))

export interface EnrollmentPolicy extends AppAttestLaunch {
    appID: string
    environment: 'production' | 'development'
}

export interface VerifiedAppAttestKey extends AppAttestLaunch {
    publicKey: string
    appID: string
    counter: number
}

export function macAttestationPolicy(value: string | undefined, bundleID: string | undefined): EnrollmentPolicy | null {
    try {
        const policy = JSON.parse(value ?? '')
        if (!bundleID || typeof policy?.appID !== 'string' || !/^[A-Z0-9]{10}\./.test(policy.appID)
            || policy.appID.slice(11) !== bundleID || !['production', 'development'].includes(policy.environment)
            || ![2, 3, 4, 5, 6].includes(policy.validationCategory)) return null
        const version = policy.bundleVersion
        if (!(typeof version === 'string' && /^\d+(\.\d+){0,2}$/.test(version) && version.length <= 32)
            && !(version === null && policy.validationCategory === 3)) return null
        return { appID: policy.appID, environment: policy.environment, validationCategory: policy.validationCategory, bundleVersion: version }
    } catch { return null }
}

function certificate(der: Uint8Array) {
    const parsed = fromDER(der, { maxDepth: 16, maxNodes: 512 })
    if (parsed.offset !== der.length) throw new Error('Invalid attestation certificate')
    return new Certificate({ schema: parsed.result })
}

function wrappedExtensionMatches(cert: Certificate, oid: string, tag: number, expected: Uint8Array) {
    const extensions = cert.extensions?.filter(extension => extension.extnID === oid)
    if (extensions?.length !== 1) return false
    const bytes = extensions[0].extnValue.valueBlock.valueHexView
    const prefix = Uint8Array.of(0x30, expected.length + 4, tag, expected.length + 2, 4, expected.length)
    return equal(bytes.subarray(0, prefix.length), prefix) && equal(bytes.subarray(prefix.length), expected)
}

function equal(a: Uint8Array, b: Uint8Array) {
    return a.length === b.length && a.every((byte, index) => byte === b[index])
}

/** Internal verifier for the macOS evidence seen so far. The trust anchor and policy are supplied by server code. */
export function createAppAttestEnrollmentVerifier(trustedRoot = decodeBase64(appleRoot)) {
    return async function verifyMacEnrollment(
        attestation: Uint8Array, keyID: string, challenge: string, policy: EnrollmentPolicy, checkDate = new Date(),
    ): Promise<VerifiedAppAttestKey | null> {
        try {
            if (attestation.length > 16_384 || !/^[A-Za-z0-9+/]{43}=$/.test(keyID)
                || !/^[a-f0-9]{64}$/.test(challenge) || !Number.isFinite(checkDate.getTime())) return null
            const object: unknown = decode(attestation, appAttestCBOR)
            if (!(object instanceof Map) || object.size !== 3 || object.get('fmt') !== 'apple-appattest') return null
            const statement: unknown = object.get('attStmt')
            const data: unknown = object.get('authData')
            if (!(statement instanceof Map) || statement.size !== 2 || !(data instanceof Uint8Array)) return null
            const chain: unknown = statement.get('x5c')
            const receipt: unknown = statement.get('receipt')
            if (!Array.isArray(chain) || chain.length !== 2 || !chain.every(cert => cert instanceof Uint8Array)
                || !(receipt instanceof Uint8Array) || !receipt.length) return null
            const [leaf, intermediate] = chain.map(certificate)
            const isCA = leaf.extensions?.some(extension => extension.parsedValue instanceof BasicConstraints && extension.parsedValue.cA)
            if (isCA) return null
            const trust = new CertificateChainValidationEngine({ trustedCerts: [certificate(trustedRoot)], certs: [intermediate, leaf], checkDate })
            const engine = Object.assign(new CryptoEngine({ crypto }), {
                timingSafeEqual: crypto.subtle.timingSafeEqual.bind(crypto.subtle)
            })
            const validation = await trust.verify({}, engine)
            if (!validation.result || validation.certificatePath?.length !== 3) return null

            if (data.length <= 87 || (data[32] & 0xc0) !== 0xc0 || !equal(data.subarray(0, 32), await sha256(encoder.encode(policy.appID)))) return null
            const header = new DataView(data.buffer, data.byteOffset, data.byteLength)
            if (header.getUint32(33) !== 0 || header.getUint16(53) !== 32) return null
            const aaguid = policy.environment === 'production' ? 'appattest\0\0\0\0\0\0\0' : 'appattestdevelop'
            if (!equal(data.subarray(37, 53), encoder.encode(aaguid))) return null
            const credentialID = decodeBase64(keyID)
            if (!equal(data.subarray(55, 87), credentialID)) return null

            const [cose, extensionsBytes] = decodeFirst(data.subarray(87), appAttestCBOR)
            const point = await credentialPublicKey(leaf, cose)
            if (!point || !equal(await sha256(point), credentialID)) return null
            if (!appAttestLaunchMatches(decode(extensionsBytes, appAttestCBOR), policy)) return null
            const nonce = await appAttestNonce(data, challenge)
            if (!wrappedExtensionMatches(leaf, '1.2.840.113635.100.8.2', 0xa1, nonce)
                || !wrappedExtensionMatches(leaf, '1.2.840.113635.100.8.6', 0xa3, decodeBase64(macAccessPolicy))) return null
            return { publicKey: base64url.encode(point), appID: policy.appID,
                validationCategory: policy.validationCategory, bundleVersion: policy.bundleVersion, counter: 0 }
        } catch { return null }
    }
}

async function credentialPublicKey(leaf: Certificate, cose: unknown) {
    if (!(cose instanceof Map) || cose.size !== 5 || cose.get(1) !== 2 || cose.get(3) !== -7 || cose.get(-1) !== 1) return null
    const key = await crypto.subtle.importKey('spki', leaf.subjectPublicKeyInfo.toSchema().toBER(false),
        { name: 'ECDSA', namedCurve: 'P-256' }, true, ['verify'])
    const raw = await crypto.subtle.exportKey('raw', key)
    if (!(raw instanceof ArrayBuffer)) return null
    const point = new Uint8Array(raw)
    const x: unknown = cose.get(-2)
    const y: unknown = cose.get(-3)
    return x instanceof Uint8Array && y instanceof Uint8Array
        && equal(point.subarray(1, 33), x) && equal(point.subarray(33), y) ? point : null
}
