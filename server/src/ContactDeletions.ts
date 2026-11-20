import { notificationAuth } from './AppleAccount'
import { verifyDeviceProof } from './DeviceIdentity'
import { json, readJSON, sha256Hex, type Env } from './types'

const path = '/api/contact-deletions'
const hex = /^[a-f0-9]{64}$/
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
const deviceKey = /^[A-Za-z0-9_-]{87}$/
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const lifetime = 28 * 86_400_000 + 300_000
const missing = () => json({ error: 'Not found' }, 404)
const unauthorized = () => json({ error: 'Unauthorized' }, 401)
const badBody = () => json({ error: 'Invalid deletion request' }, 400)

function field(value: unknown, format: RegExp): string {
    if (typeof value !== 'string' || !format.test(value)) throw new Error('body')
    return value
}
function packet(value: unknown): string {
    if (typeof value !== 'string' || value.length < 40 || value.length > 4096) throw new Error('body')
    return field(value, base64)
}
function expiry(value: unknown): number {
    const now = Date.now()
    if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= now || value > now + lifetime) throw new Error('body')
    return value
}
function stateResponse(state: string): Response {
    switch (state) {
        case 'pending': case 'received': case 'retired': return json({ state })
        case 'expired': return badBody()
        case 'unauthorized': return unauthorized()
        case 'conflict': return json({ error: 'Deletion slot already used' }, 409)
        case 'limited': return json({ error: 'Pending deletion limit reached' }, 429)
        default: return missing()
    }
}

export async function contactDeletionRequest(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url), method = request.method
    const ownerWrite = url.pathname === path && (method === 'PUT' || method === 'DELETE')
    const read = url.pathname === path + '/read' && method === 'POST'
    const receipt = url.pathname === path + '/receipt' && method === 'PUT'
    if (!ownerWrite && !read && !receipt) return missing()

    const bearer = request.headers.get('Authorization') ?? ''
    const token = bearer.startsWith('Bearer ') && bearer.length <= 512 ? bearer.slice(7) : ''
    try {
        const auth = await notificationAuth(token, env)
        if (!auth) return unauthorized()
        if (!(await env.CALL_API_LIMIT.limit({ key: 'contact-deletion:' + auth.accountID })).success) {
            return json({ error: 'Too many deletion requests' }, 429)
        }
        const own = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(auth.accountID))
        const index = (owner: string) => env.NOTIFICATION_INDEX.get(env.NOTIFICATION_INDEX.idFromName('user:' + owner))
        const body = await readJSON(request) as Record<string, unknown>
        const slot = field(body.slot, hex)
        const slotHash = await sha256Hex(slot)

        if (ownerWrite) {
            const id = field(body.id, uuid)
            const expiresAt = expiry(body.expiresAt)
            if (method === 'DELETE') return stateResponse(await own.contactDeletionRetire(auth, slotHash, { id, expiresAt }))
            const recipient = field(body.recipient, hex)
            if (recipient === auth.userID) return badBody()
            const recipientKey = field(body.recipientKey, deviceKey)
            const notice = packet(body.packet)
            const state = await own.contactDeletionPublish(auth, slotHash, {
                id, expiresAt, recipient, recipientKey, packet: notice, packetHash: await sha256Hex(notice)
            })
            // Public routing can outlive the sender's session while the slot is pending.
            if (state === 'pending' || state === 'received') {
                if (!await own.notificationAuthorized(auth)) return unauthorized()
                await index(auth.userID).bind({ accountID: auth.accountID, userID: auth.userID, expiresAt })
            }
            return stateResponse(state)
        }

        const owner = field(body.owner, hex)
        if (read && owner === auth.userID) {
            const saved = await own.contactDeletionReceipt(auth, slotHash)
            return saved ? json({ receipt: saved }) : missing()
        }
        if (owner === auth.userID || !body.proof || typeof body.proof !== 'object' || Array.isArray(body.proof)) return missing()
        const id = receipt ? field(body.id, uuid) : ''
        const sealedReceipt = receipt ? packet(body.packet) : ''
        const values = receipt ? [owner, slot, id, sealedReceipt] : [owner, slot]
        const proof = await verifyDeviceProof(auth, url.origin, receipt ? 'acknowledgeContactDeletionRelay' : 'readContactDeletion',
            JSON.stringify(values), body.proof as Record<string, unknown>, env)
        if (!proof) return missing()
        const route = await index(owner).current()
        if (route?.userID !== owner || !await own.notificationAuthorized(auth)) return missing()
        const sender = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
        if (read) {
            const saved = await sender.contactDeletionNotice(owner, slotHash, auth.userID, proof.recipientKey)
            return saved && await own.notificationAuthorized(auth) ? json({ deletion: saved }) : missing()
        }
        return stateResponse(await sender.contactDeletionAcknowledge(owner, slotHash, auth.userID, proof.recipientKey, id, sealedReceipt))
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? badBody() : json({ error: 'Deletion delivery unavailable' }, 503)
    }
}
