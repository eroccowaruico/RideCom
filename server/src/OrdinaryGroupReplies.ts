import { notificationAuth } from './AppleAccount'
import { groupInvitationLifetime } from './AccountNotifications'
import type { OrdinaryGroupReplyStatus } from './AccountOrdinaryGroupReplies'
import { json, readJSON, sha256Hex, type Env } from './types'

export const ordinaryGroupReplyPrefix = '/api/ordinary-group-replies/'
const hex = /^[a-f0-9]{64}$/
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const notFound = () => json({ error: 'Not found' }, 404)
const unauthorized = () => json({ error: 'Unauthorized' }, 401)
const badBody = () => json({ error: 'Invalid group reply request' }, 400)

function field(value: unknown, format: RegExp, length: number): string {
    if (typeof value !== 'string' || value.length > length || !format.test(value)) throw new Error('body')
    return value
}

function packet(id: string, value: unknown) {
    const encoded = field(value, base64, 12 * 1024)
    if (encoded.length < 40 || encoded.length % 4 !== 0) throw new Error('body')
    return { id, packet: encoded }
}

function status(value: OrdinaryGroupReplyStatus): Response {
    switch (value) {
        case 'ok': return json({})
        case 'expired': return badBody()
        case 'conflict': return json({ error: 'Group reply already exists' }, 409)
        case 'limited': return json({ error: 'Group reply limit reached' }, 429)
        case 'unauthorized': return unauthorized()
        case 'missing': return notFound()
    }
}

export async function ordinaryGroupReplyRequest(request: Request, env: Env): Promise<Response> {
    const action = new URL(request.url).pathname.slice(ordinaryGroupReplyPrefix.length)
    const method = request.method
    const read = action === 'inbox' || action === 'receipt'
    const write = action === 'open' || action === 'acceptance' || action === 'acknowledgement'
    if (!(read && method === 'POST') && !(write && method === 'PUT')) return notFound()

    const bearer = request.headers.get('Authorization') ?? ''
    const token = bearer.startsWith('Bearer ') && bearer.length <= 512 ? bearer.slice(7) : ''
    try {
        const auth = await notificationAuth(token, env)
        if (!auth) return unauthorized()
        if (!(await env.CALL_API_LIMIT.limit({ key: 'ordinary-group-reply:' + auth.accountID })).success) {
            return json({ error: 'Too many group reply requests' }, 429)
        }
        const body = await readJSON(request) as Record<string, unknown>
        const slotHash = await sha256Hex(field(body.slot, hex, 64))
        const account = (accountID: string) => env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(accountID))
        const index = (userID: string) => env.NOTIFICATION_INDEX.get(env.NOTIFICATION_INDEX.idFromName('user:' + userID))
        const own = account(auth.accountID)

        if (action === 'open') {
            const expiresAt = body.expiresAt, now = Date.now()
            if (typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt) || expiresAt <= now || expiresAt > now + groupInvitationLifetime) return badBody()
            const result = await own.ordinaryGroupReplyOpen(auth, slotHash, expiresAt)
            if (result === 'ok') {
                if (!await own.notificationAuthorized(auth)) return unauthorized()
                await index(auth.userID).bind({ accountID: auth.accountID, userID: auth.userID, expiresAt })
            }
            return status(result)
        }
        if (action === 'inbox') {
            const acceptances = await own.ordinaryGroupReplyInbox(auth, slotHash)
            return acceptances ? json({ acceptances }) : notFound()
        }

        const id = field(body.id, uuid, 36)
        if (action === 'acknowledgement') return status(await own.ordinaryGroupReplyAcknowledge(auth, slotHash, packet(id, body.packet)))
        const owner = field(body.owner, hex, 64)
        const value = action === 'acceptance' ? packet(id, body.packet) : null
        const route = await index(owner).current()
        if (route?.userID !== owner) return notFound()
        const recipient = await sha256Hex(auth.userID + ':' + auth.deviceID)
        if (!await own.notificationAuthorized(auth)) return unauthorized()
        const destination = account(route.accountID)
        if (value) return status(await destination.ordinaryGroupReplyAccept(owner, slotHash, recipient, value))
        const receipt = await destination.ordinaryGroupReplyReceipt(owner, slotHash, recipient, id)
        return receipt && await own.notificationAuthorized(auth) ? json({ receipt }) : notFound()
    } catch (error) {
        return error instanceof Error && error.message === 'body' ? badBody() : json({ error: 'Group reply service unavailable' }, 503)
    }
}
