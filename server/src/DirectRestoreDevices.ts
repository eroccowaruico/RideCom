import { restoreDeviceClockTolerance, restoreDeviceLifetime } from './AccountDirectRestoreDevices'
import { notificationAuth } from './AppleAccount'
import { verifyDeviceProof } from './DeviceIdentity'
import { publicAccountIndex } from './NotificationIndex'
import { isRecord, json, readJSON, sha256Hex, type Env } from './types'

export const directRestoreDevicePath = '/api/direct-call-restore/device'
const hex = /^[a-f0-9]{64}$/
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const missing = () => json({ error: 'Not found' }, 404)
const unauthorized = () => json({ error: 'Unauthorized' }, 401)

async function scope(slot: string, reader: string) { return sha256Hex(JSON.stringify([slot, reader])) }

export async function directRestoreDeviceRequest(request: Request, url: URL, env: Env): Promise<Response> {
    if (env.DIRECT_CALL_RESTORE_RELAY_ENABLED !== 'true') return missing()
    const method = request.method
    if (!['POST', 'PUT', 'DELETE'].includes(method)) return json({ error: 'Method not allowed' }, 405)
    try {
        const bearer = request.headers.get('Authorization') ?? ''
        const auth = bearer.startsWith('Bearer ') && bearer.length <= 512
            ? await notificationAuth(bearer.slice(7), env) : null
        if (!auth) return unauthorized()
        if (!(await env.CALL_API_LIMIT.limit({ key: `direct-restore-device:${auth.accountID}` })).success) {
            return json({ error: 'Too many restore requests' }, 429)
        }
        const body = await readJSON(request)
        const { slot } = body
        if (typeof slot !== 'string' || !hex.test(slot)) throw new Error('body')
        const own = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(auth.accountID))
        if (method === 'POST') {
            const { owner } = body
            if (Object.keys(body).length !== 2 || typeof owner !== 'string' || !hex.test(owner)
                || owner === auth.userID) throw new Error('body')
            const route = await publicAccountIndex(env, owner).current()
            if (!route || route.userID !== owner) return missing()
            const account = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
            const publication = await account.directRestoreDeviceRead(owner, await scope(slot, auth.userID))
            if (!await own.notificationAuthorized(auth)) return unauthorized()
            return publication ? json(publication) : missing()
        }
        const { reader } = body
        if (typeof reader !== 'string' || !hex.test(reader) || reader === auth.userID) throw new Error('body')
        const key = await scope(slot, reader)
        if (method === 'DELETE') {
            if (Object.keys(body).length !== 2) throw new Error('body')
            return writeResult(await own.directRestoreDeviceRevoke(auth, key))
        }
        const { issuedAt, expiresAt, packet, proof } = body
        const now = Date.now()
        if (Object.keys(body).length !== 6 || typeof issuedAt !== 'number' || !Number.isSafeInteger(issuedAt)
            || issuedAt > now + restoreDeviceClockTolerance || typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt)
            || expiresAt <= now || expiresAt <= issuedAt || expiresAt > issuedAt + restoreDeviceLifetime
            || typeof packet !== 'string' || packet.length < 40 || packet.length > 8192
            || !base64.test(packet) || !isRecord(proof)) throw new Error('body')
        const sessionBinding = await sha256Hex(auth.tokenHash)
        const verified = await verifyDeviceProof({ ...auth, sessionBinding }, url.origin, 'publishDirectRestoreDevice',
            JSON.stringify([slot, reader, issuedAt, expiresAt, packet]), proof, env)
        if (!verified) return unauthorized()
        if (expiresAt > verified.expiresAt) throw new Error('body')
        return writeResult(await own.directRestoreDevicePublish(auth, key, {
            deviceID: auth.deviceID, sessionBinding, issuedAt, expiresAt, packet }))
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? json({ error: 'Invalid restore request' }, 400) : json({ error: 'Restore delivery unavailable' }, 503)
    }
}

function writeResult(state: 'unauthorized' | 'expired' | 'stored' | 'revoked' | 'conflict' | 'limited') {
    switch (state) {
        case 'unauthorized': return unauthorized()
        case 'expired': return json({ error: 'Invalid restore request' }, 400)
        case 'conflict': return json({ error: 'Restore publication conflicts' }, 409)
        case 'limited': return json({ error: 'Pending restore publication limit reached' }, 429)
        default: return json({ state })
    }
}
