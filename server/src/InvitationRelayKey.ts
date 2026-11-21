import { base64url } from 'jose'

const periodSeconds = 30 * 86400
const domain = new TextEncoder().encode('rideintercom.invitation-relay-key.v1')
// RFC 8410 PrivateKeyInfo for a 32-byte X25519 private key.
const x25519Prefix = Uint8Array.of(0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20)
const x25519BasePoint = new Uint8Array(32)
x25519BasePoint[0] = 9

export async function currentInvitationRelayKey(seed: string | undefined, origin: string, issuedAt: number) {
    const period = Math.floor(issuedAt / periodSeconds)
    const key = await deriveInvitationRelayKey(seed, origin, period)
    if (!key) return undefined
    const basePoint = await crypto.subtle.importKey('raw', x25519BasePoint, 'X25519', false, [])
    // RFC 7748 derives the public coordinate by multiplying the base point without exporting the private key.
    const agreement = { name: 'X25519', public: basePoint }
    const x = base64url.encode(new Uint8Array(await crypto.subtle.deriveBits(agreement, key, 256)))
    return { kid: `v1-${period}`, x, expiresAt: (period + 2) * periodSeconds }
}

export async function invitationRelayDecryptionKey(seed: string | undefined, origin: string, kid: string, now: number) {
    const currentPeriod = Math.floor(now / periodSeconds)
    const period = kid === `v1-${currentPeriod}` ? currentPeriod : currentPeriod - 1
    if (kid !== `v1-${period}`) return null
    const key = await deriveInvitationRelayKey(seed, origin, period)
    if (!key) throw new Error('configuration')
    return key
}

async function deriveInvitationRelayKey(seed: string | undefined, origin: string, period: number) {
    if (!seed || !/^[A-Za-z0-9_-]{43}$/.test(seed)) return undefined
    const seedBytes = base64url.decode(seed)
    if (seedBytes.length !== 32 || base64url.encode(seedBytes) !== seed) return undefined

    const rootKey = await crypto.subtle.importKey('raw', seedBytes, 'HKDF', false, ['deriveBits'])
    const info = new TextEncoder().encode(JSON.stringify([origin, period]))
    const material = await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: domain, info }, rootKey, 256)
    const pkcs8 = new Uint8Array(x25519Prefix.length + 32)
    pkcs8.set(x25519Prefix)
    pkcs8.set(new Uint8Array(material), x25519Prefix.length)
    return crypto.subtle.importKey('pkcs8', pkcs8, 'X25519', false, ['deriveBits'])
}
