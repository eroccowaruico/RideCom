import { notificationAuth } from './AppleAccount'
import { verifyDeviceProof } from './DeviceIdentity'
import { publicAccountIndex } from './NotificationIndex'
import { isRecord, json, readJSON, sha256Hex, type Env } from './types'

export const directRestoreRelayPath = '/api/direct-call-restore/relay'
const hex = /^[a-f0-9]{64}$/
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const missing = () => json({ error: 'Not found' }, 404)
const unauthorized = () => json({ error: 'Unauthorized' }, 401)

function field(value: unknown, pattern: RegExp) {
    if (typeof value !== 'string' || !pattern.test(value)) throw new Error('body')
    return value
}

export async function directRestoreRelayRequest(request: Request, url: URL, env: Env): Promise<Response> {
    if (env.DIRECT_CALL_RESTORE_RELAY_ENABLED !== 'true') return missing()
    const method = request.method
    if (!['GET', 'PUT', 'DELETE'].includes(method)) return json({ error: 'Method not allowed' }, 405)
    try {
        const bearer = request.headers.get('Authorization') ?? ''
        const auth = bearer.startsWith('Bearer ') && bearer.length <= 512
            ? await notificationAuth(bearer.slice(7), env) : null
        if (!auth) return unauthorized()
        if (!(await env.CALL_API_LIMIT.limit({ key: `direct-restore:${auth.accountID}` })).success) {
            return json({ error: 'Too many restore requests' }, 429)
        }
        const sessionBinding = await sha256Hex(auth.tokenHash)
        const own = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(auth.accountID))
        if (method === 'GET') {
            const candidates = await own.directRestoreRelayPending(auth, sessionBinding)
            const messages = await Promise.all(candidates.map(async candidate => {
                const { sender } = candidate
                const route = await publicAccountIndex(env, sender.userID).current()
                if (!route || route.userID !== sender.userID) return null
                const account = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
                if (!await account.authenticateBoundSession(sender.userID, sender.deviceID, sender.sessionBinding)) return null
                return own.directRestoreRelayRead(auth, sessionBinding, candidate)
            }))
            if (!await own.notificationAuthorized(auth)) return unauthorized()
            return json({ messages: messages.filter(message => message !== null) })
        }
        const body = await readJSON(request)
        const id = field(body.id, uuid)
        if (method === 'DELETE') {
            if (Object.keys(body).length !== 1) throw new Error('body')
            return await own.directRestoreRelayRetire(auth, sessionBinding, id) ? json({ state: 'retired' }) : missing()
        }
        const allowed = ['id', 'recipient', 'deviceID', 'sessionBinding', 'expiresAt', 'packet', 'proof']
        if (Object.keys(body).some(key => !allowed.includes(key))) throw new Error('body')
        const recipient = field(body.recipient, hex), deviceID = field(body.deviceID, uuid)
        const recipientBinding = field(body.sessionBinding, hex)
        const { expiresAt, packet, proof } = body
        const now = Date.now()
        if (recipient === auth.userID || typeof packet !== 'string' || packet.length < 40 || packet.length > 24_576
            || !base64.test(packet) || typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt)
            || expiresAt <= now || expiresAt > now + 300_000 || !isRecord(proof)) throw new Error('body')
        const signed = JSON.stringify([recipient, deviceID, recipientBinding, id, expiresAt, packet])
        if (!await verifyDeviceProof({ ...auth, sessionBinding }, url.origin, 'submitDirectCallRestoreRelay', signed, proof, env)) {
            return unauthorized()
        }
        const route = await publicAccountIndex(env, recipient).current()
        if (!route || route.userID !== recipient) return missing()
        const packetHash = await sha256Hex(packet)
        if (!await own.notificationAuthorized(auth)) return unauthorized()
        const target = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
        const state = await target.directRestoreRelayPut(recipient, { id, expiresAt, packet, packetHash,
            sender: { userID: auth.userID, deviceID: auth.deviceID, sessionBinding },
            recipient: { deviceID, sessionBinding: recipientBinding } })
        switch (state) {
            case 'queued': case 'retired': return json({ state })
            case 'conflict': return json({ error: 'Restore request already used' }, 409)
            case 'limited': return json({ error: 'Pending restore request limit reached' }, 429)
            case 'expired': throw new Error('body')
            default: return missing()
        }
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? json({ error: 'Invalid restore request' }, 400) : json({ error: 'Restore delivery unavailable' }, 503)
    }
}
