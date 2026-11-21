import { base64url, importJWK, jwtVerify, SignJWT } from 'jose'
import { type Env, isRecord } from './types'
import type { DeviceIdentity } from './AppleAccount'
import { currentInvitationRelayKey } from './InvitationRelayKey'

function memberIDIsValid(value: unknown): value is string {
    return typeof value === 'string' && /^[A-Za-z0-9_-]{1,63}$/.test(value) && !value.startsWith('invite-pending-')
}

export async function importP256VerificationKey(value: unknown) {
    if (typeof value !== 'string' || value.length !== 87) throw new Error('body')
    const bytes = base64url.decode(value)
    if (bytes.length !== 65 || bytes[0] !== 4 || base64url.encode(bytes) !== value) throw new Error('body')
    return crypto.subtle.importKey('raw', bytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
}

export function deviceSigningKey(env: Env) {
    if (!env.DEVICE_IDENTITY_SIGNING_KEY) throw new Error('configuration')
    const stored: unknown = JSON.parse(env.DEVICE_IDENTITY_SIGNING_KEY)
    if (!isRecord(stored) || stored.kty !== 'EC' || stored.crv !== 'P-256' || typeof stored.d !== 'string'
        || typeof stored.x !== 'string' || typeof stored.y !== 'string') throw new Error('configuration')
    return { ...stored, kty: stored.kty, crv: stored.crv, x: stored.x, y: stored.y, d: stored.d }
}

function issuerKeys(env: Env) {
    const stored = deviceSigningKey(env)
    const x = base64url.decode(stored.x), y = base64url.decode(stored.y)
    if (x.length !== 32 || y.length !== 32) throw new Error('configuration')
    const key = { kty: 'EC', crv: 'P-256', x: stored.x, y: stored.y }
    const issuerKey = base64url.encode(new Uint8Array([4, ...x, ...y]))
    return { key, privateScalar: stored.d, issuerKey }
}

export async function certifyDevice(identity: DeviceIdentity & { sessionBinding: string }, issuer: string, body: Record<string, unknown>, env: Env) {
    const memberID = body.memberID, deviceKey = body.deviceKey
    if (!memberIDIsValid(memberID)) throw new Error('body')
    try { await importP256VerificationKey(deviceKey) } catch { throw new Error('body') }
    const { key, privateScalar, issuerKey } = issuerKeys(env)
    const signingKey = await importJWK({ ...key, d: privateScalar }, 'ES256')
    const issuedAt = Math.floor(Date.now() / 1000)
    const expiresAt = Math.min(Math.floor(identity.expiresAt / 1000), issuedAt + 30 * 86400)
    if (expiresAt <= issuedAt) throw new Error('expired')
    const invitationRelayKey = await currentInvitationRelayKey(env.INVITATION_RELAY_KEY_SEED, issuer, issuedAt)
    const certificate = await new SignJWT({ deviceID: identity.deviceID, memberID, deviceKey, sessionBinding: identity.sessionBinding, invitationRelayKey })
        .setProtectedHeader({ alg: 'ES256', typ: 'rideintercom-device+jwt' })
        .setIssuer(issuer).setSubject(identity.userID).setAudience('rideintercom-peer')
        .setIssuedAt(issuedAt).setExpirationTime(expiresAt).sign(signingKey)
    return { certificate, issuerKey }
}

/** Matches DeviceIdentityProof's length-prefixed signature input used by the App. */
function proofMessage(fields: string[]) {
    const encoder = new TextEncoder()
    const prefix = encoder.encode('rideintercom.device-proof.v1\0')
    const values = fields.map(value => encoder.encode(value))
    const message = new Uint8Array(prefix.length + values.reduce((size, value) => size + 4 + value.length, 0))
    const lengths = new DataView(message.buffer)
    message.set(prefix)
    let offset = prefix.length
    for (const value of values) {
        lengths.setUint32(offset, value.length)
        message.set(value, offset + 4)
        offset += 4 + value.length
    }
    return message
}

export async function verifyDeviceProof(
    identity: Pick<DeviceIdentity, 'userID' | 'deviceID'> & { sessionBinding?: string }, issuer: string, purpose: string, payload: string,
    body: Record<string, unknown>, env: Env
) {
    const { publicKey, certificate, signature } = body
    if (typeof publicKey !== 'string' || publicKey.length !== 87 || typeof signature !== 'string' || signature.length !== 86
        || !certificate || typeof certificate !== 'object' || !('certificate' in certificate) || !('issuerKey' in certificate)) return null
    const compact = certificate.certificate
    if (typeof compact !== 'string' || compact.length > 4096) return null
    const { key, issuerKey } = issuerKeys(env)
    if (certificate.issuerKey !== issuerKey) return null
    try {
        const { payload: claims, protectedHeader } = await jwtVerify(compact, await importJWK(key, 'ES256'), {
            issuer, subject: identity.userID, audience: 'rideintercom-peer', algorithms: ['ES256'],
            requiredClaims: ['iat', 'exp', 'deviceID', 'memberID', 'deviceKey']
        })
        if (protectedHeader.typ !== 'rideintercom-device+jwt' || claims.deviceID !== identity.deviceID
            || (identity.sessionBinding !== undefined && claims.sessionBinding !== identity.sessionBinding)
            || !memberIDIsValid(claims.memberID) || claims.deviceKey !== publicKey || typeof claims.iat !== 'number'
            || typeof claims.exp !== 'number' || !Number.isSafeInteger(claims.iat) || !Number.isSafeInteger(claims.exp)
            || claims.iat < 0 || claims.iat > Date.now() / 1000 + 60
            || claims.exp <= claims.iat || claims.exp - claims.iat > 30 * 86400) return null
        const bytes = base64url.decode(signature)
        if (bytes.length !== 64 || base64url.encode(bytes) !== signature) return null
        const verified = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, await importP256VerificationKey(publicKey), bytes,
            proofMessage([purpose, claims.memberID, publicKey, compact, issuerKey, payload]))
        return verified ? { memberID: claims.memberID, recipientKey: publicKey, expiresAt: claims.exp * 1000 } : null
    } catch { return null }
}
