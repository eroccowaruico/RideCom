import { importP256VerificationKey } from './DeviceIdentity'

interface RegisteredDevice {
    publicKey: string
    appID: string
    validationCategory: number
    bundleVersion: string
    counter: number
    challenge?: { nonce: string; operationHash: string; expiresAt: number }
}

const hexDigest = /^[a-f0-9]{64}$/
const encoder = new TextEncoder()

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
        const record = decodeFields(assertion)
        const signature = record.get('signature'), data = record.get('authenticatorData')
        if (!(signature instanceof Uint8Array) || !(data instanceof Uint8Array) || data.length <= 37
            || (data[32] & 0xc0) !== 0x80) return null // Extensions present, no attestation credential data.
        const counter = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(33)
        if (!Number.isSafeInteger(device.counter) || device.counter < 0 || counter <= device.counter) return null
        const extensions = decodeFields(data.subarray(37))
        const category = extensions.get('apple_validation_category_01')
        const version = extensions.get('apple_bundle_version_01')
        if (!(category instanceof Uint8Array) || category.length !== 4 || typeof version !== 'string' || !version.length
            || new DataView(category.buffer, category.byteOffset, 4).getUint32(0, true) !== device.validationCategory
            || version !== device.bundleVersion) return null
        const rpID = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(device.appID)))
        if (!rpID.every((byte, index) => byte === data[index])) return null
        const clientHash = new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(clientData)))
        const signed = new Uint8Array(data.length + clientHash.length)
        signed.set(data)
        signed.set(clientHash, data.length)
        // Web Crypto hashes signed once to obtain Apple's nonce and expects raw P-256 scalars.
        const key = await importP256VerificationKey(device.publicKey)
        return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, rawSignature(signature), signed) ? counter : null
    } catch { return null }
}

/** Both App Attest records used here are maps of two text keys with byte-string or text values. */
function decodeFields(bytes: Uint8Array) {
    const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })
    let offset = 0
    function take(count: number) {
        if (offset + count > bytes.length) throw new Error('Truncated assertion')
        const value = bytes.slice(offset, offset + count)
        offset += count
        return value
    }
    function length(type: number) {
        const head = take(1)[0]
        if (head >> 5 !== type) throw new Error('Unexpected assertion field')
        const code = head & 31
        if (code < 24) return code
        if (code === 24) return take(1)[0]
        if (code === 25) return new DataView(take(2).buffer).getUint16(0)
        throw new Error('Unexpected assertion field length')
    }
    if (length(5) !== 2) throw new Error('Unexpected assertion record')
    const fields = new Map<string, string | Uint8Array<ArrayBuffer>>()
    for (let i = 0; i < 2; i++) {
        const key = decoder.decode(take(length(3)))
        if (fields.has(key)) throw new Error('Duplicate assertion field')
        const type = bytes[offset] >> 5
        if (type !== 2 && type !== 3) throw new Error('Unexpected assertion value')
        const value = take(length(type))
        fields.set(key, type === 3 ? decoder.decode(value) : value)
    }
    if (bytes.length !== offset) throw new Error('Trailing assertion data')
    return fields
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
