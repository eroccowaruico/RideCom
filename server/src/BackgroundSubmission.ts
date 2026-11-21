import { base64url, compactDecrypt, decodeProtectedHeader } from 'jose'
import { verifyDeviceProof } from './DeviceIdentity'
import { invitationRelayDecryptionKey } from './InvitationRelayKey'
import { publicAccountIndex } from './NotificationIndex'
import { readJSON, type Env } from './types'

const hex = /^[a-f0-9]{64}$/
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const fields = ['senderUserID', 'deviceID', 'sessionBinding', 'submission', 'proof']
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })

type Purpose = 'submitBackgroundGroupInvitation' | 'cancelBackgroundGroupInvitation'
    | 'submitBackgroundContactInvitationAcceptance'

function parseSubmission(bytes: Uint8Array): Record<string, unknown> {
    let value: unknown
    try { value = JSON.parse(decoder.decode(bytes)) } catch { throw new Error('body') }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('body')
    return value as Record<string, unknown>
}

export async function openSealedInvitationSubmission(request: Request, origin: string, env: Env) {
    const { sealed, ...extra } = await readJSON(request)
    if (Object.keys(extra).length !== 0 || typeof sealed !== 'string') throw new Error('body')
    if (sealed.split('.', 1)[0].length > 512) throw new Error('body')
    let header: ReturnType<typeof decodeProtectedHeader>
    try { header = decodeProtectedHeader(sealed) } catch { throw new Error('body') }
    const { alg, enc, kid, epk, ...otherFields } = header
    if (Object.keys(otherFields).length !== 0 || alg !== 'ECDH-ES' || enc !== 'A256GCM'
        || typeof kid !== 'string' || !/^v1-[0-9]{1,9}$/.test(kid)
        || !epk || typeof epk !== 'object' || Array.isArray(epk)) throw new Error('body')
    const { kty, crv, x, ...otherKeyFields } = epk as Record<string, unknown>
    if (Object.keys(otherKeyFields).length !== 0 || kty !== 'OKP' || crv !== 'X25519'
        || typeof x !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(x)
        || base64url.encode(base64url.decode(x)) !== x) throw new Error('body')

    const key = await invitationRelayDecryptionKey(env.INVITATION_RELAY_KEY_SEED, origin, kid, Date.now() / 1000)
    if (!key) return null
    let clear: Uint8Array
    try {
        const decrypted = await compactDecrypt(sealed, key, { keyManagementAlgorithms: [alg], contentEncryptionAlgorithms: [enc] })
        clear = decrypted.plaintext
    } catch { return null }
    return parseSubmission(clear)
}

export async function authenticateBackgroundSubmission(body: Record<string, unknown>, origin: string, purpose: Purpose, env: Env) {
    const { senderUserID, deviceID, sessionBinding, submission, proof } = body
    if (Object.keys(body).some(key => !fields.includes(key))
        || typeof senderUserID !== 'string' || !hex.test(senderUserID)
        || typeof deviceID !== 'string' || !uuid.test(deviceID)
        || typeof sessionBinding !== 'string' || !hex.test(sessionBinding)
        || typeof submission !== 'string' || submission.length === 0 || submission.length > 36 * 1024
        || !base64.test(submission) || !proof || typeof proof !== 'object' || Array.isArray(proof)) throw new Error('body')

    const identity = { userID: senderUserID, deviceID, sessionBinding }
    const message = JSON.stringify([origin, sessionBinding, submission])
    if (!await verifyDeviceProof(identity, origin, purpose, message, proof as Record<string, unknown>, env)) return null

    const value = parseSubmission(Uint8Array.from(atob(submission), character => character.charCodeAt(0)))

    const route = await publicAccountIndex(env, senderUserID).current()
    if (route?.userID !== senderUserID) return null
    const owner = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
    const auth = await owner.authenticateBoundSession(senderUserID, deviceID, sessionBinding)
    return auth ? { auth, body: value } : null
}
