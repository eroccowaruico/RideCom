import { decode } from 'cborg'
import { importP256VerificationKey } from './DeviceIdentity'
import { type AppAttestLaunch, appAttestCBOR, appAttestLaunchMatches, appAttestNonce, sha256 } from './AppAttestData'

interface RegisteredDevice extends AppAttestLaunch {
    publicKey: string
    appID: string
    counter: number
    challenge?: { nonce: string; operationHash: string; expiresAt: number }
}

const hexDigest = /^[a-f0-9]{64}$/
const encoder = new TextEncoder()
// Preserve the accepted definite-length assertion encodings, including nonminimal lengths.
const assertionCBOR = { ...appAttestCBOR, strict: false }

/** The caller selects this device record from its authenticated account.
 * The stored public key and app identity must come from verified enrollment. */
export async function consumeGroupRemovalAssertion(
    storage: DurableObjectStorage, deviceKey: string, operationHash: string, assertion: Uint8Array,
): Promise<number | null> {
    const initial = storage.kv.get<RegisteredDevice>(deviceKey)
    const challenge = initial?.challenge
    if (!initial || !challenge || !hexDigest.test(challenge.nonce) || !hexDigest.test(operationHash)
        || operationHash !== challenge.operationHash || !Number.isSafeInteger(challenge.expiresAt)
        || challenge.expiresAt <= Date.now() || assertion.length > 4096) return null
    const clientData = JSON.stringify(['rideintercom.group-removal.v1', challenge.nonce, operationHash])
    const counter = await verifiedCounter(assertion, clientData, initial)
    if (counter === null) return null
    // Verification yields. A second request may already have used this challenge
    // or received a newer one before the signature check returns.
    return storage.transactionSync(() => {
        const latest = storage.kv.get<RegisteredDevice>(deviceKey)
        if (!latest?.challenge || latest.challenge.expiresAt <= Date.now()
            || JSON.stringify(latest) !== JSON.stringify(initial)) return null
        delete latest.challenge
        latest.counter = counter
        storage.kv.put(deviceKey, latest)
        return counter
    })
}

async function verifiedCounter(assertion: Uint8Array, clientData: string, device: RegisteredDevice): Promise<number | null> {
    try {
        const record: unknown = decode(assertion, assertionCBOR)
        if (!(record instanceof Map) || record.size !== 2) return null
        const signature: unknown = record.get('signature')
        const data: unknown = record.get('authenticatorData')
        if (!(signature instanceof Uint8Array) || !(data instanceof Uint8Array) || data.length <= 37
            || (data[32] & 0x80) === 0) return null
        const counter = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(33)
        if (!Number.isSafeInteger(device.counter) || device.counter < 0 || counter <= device.counter) return null
        // macOS sets the attested-credential flag even though an assertion carries only extensions after the header.
        if (!appAttestLaunchMatches(decode(data.subarray(37), assertionCBOR), device)) return null
        const rpID = await sha256(encoder.encode(device.appID))
        if (!rpID.every((byte, index) => byte === data[index])) return null
        const nonce = await appAttestNonce(data, clientData)
        // App Attest signs the nonce using ECDSA with SHA-256. Web Crypto hashes this input and expects raw P-256 scalars.
        const key = await importP256VerificationKey(device.publicKey)
        return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, rawSignature(signature), nonce) ? counter : null
    } catch { return null }
}

function rawSignature(der: Uint8Array) {
    if (der.length < 8 || der.length > 72 || der[0] !== 0x30 || der[1] !== der.length - 2) {
        throw new Error('Invalid P-256 signature')
    }
    const raw = new Uint8Array(64)
    let offset = 2
    for (const end of [32, 64]) {
        if (der[offset++] !== 2) throw new Error('Invalid signature scalar')
        const size = der[offset++]
        let value = der.subarray(offset, offset + size)
        offset += size
        if (!size || value.length !== size || value[0] >= 0x80) throw new Error('Invalid signature scalar')
        if (value.length > 1 && value[0] === 0) {
            if (value[1] < 0x80) throw new Error('Invalid signature scalar padding')
            value = value.subarray(1)
        }
        if (value.length > 32) throw new Error('Oversized signature scalar')
        raw.set(value, end - value.length)
    }
    if (offset !== der.length) throw new Error('Trailing signature data')
    return raw
}
