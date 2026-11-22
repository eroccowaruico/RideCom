import { SignalingRoom } from './SignalingRoom'
import { UsageGuard } from './UsageGuard'
import { type Env, isRecord, json, sha256Hex } from './types'
import { accountRequest, authenticateDevice } from './AppleAccount'
import { notificationRequest } from './Notifications'
import { contactDeletionRequest } from './ContactDeletions'
import { directRestoreRelayPath, directRestoreRelayRequest } from './DirectRestoreRelay'
import { ordinaryGroupReplyPrefix, ordinaryGroupReplyRequest } from './OrdinaryGroupReplies'
export { NotificationIndex } from './NotificationIndex'
export { SignalingRoom, UsageGuard }
export { AppleAuthAttempt, UserAccount } from './AppleAccount'
export { consumeGroupRemovalAssertion } from './GroupRemovalAssertion'
export { createAppAttestEnrollmentVerifier } from './AppAttestEnrollment'
export { AppAttestKeyIndex } from './AppAttestKeyIndex'

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url)
        if (url.pathname === '/health' && request.method === 'GET') return json({ service: 'RideCom SFU', protocol: 1 })
        if (url.pathname.startsWith('/api/notifications/')) return notificationRequest(request, env)
        if (url.pathname.startsWith(ordinaryGroupReplyPrefix)) return ordinaryGroupReplyRequest(request, env)
        if (url.pathname === directRestoreRelayPath) return directRestoreRelayRequest(request, url, env)
        if (url.pathname === '/api/contact-deletions' || url.pathname.startsWith('/api/contact-deletions/')) {
            return contactDeletionRequest(request, env)
        }
        if (url.pathname.startsWith('/api/auth/')) return accountRequest(request, env)
        // Every billable operation is behind a per-device credential. No shared application secret in clients.
        const authorization = request.headers.get('Authorization') ?? ''
        if (!authorization.startsWith('Bearer ') || authorization.length > 512) return json({ error: 'Unauthorized' }, 401)
        const credential = authorization.slice(7)
        let device: Awaited<ReturnType<typeof authenticateDevice>>
        try { device = await authenticateDevice(credential, env) }
        catch { return json({ error: 'Account service unavailable' }, 503) }
        let owner: string | undefined
        if (device) owner = `${device.userID}:${device.deviceID}`
        else if (!credential.startsWith('ri1.')) {
            const hash = await sha256Hex(credential)
            try {
                const tokens: unknown = JSON.parse(env.CLIENT_TOKENS_JSON || '{}')
                const value = isRecord(tokens) ? tokens[hash] : undefined
                if (typeof value === 'string') owner = value
            } catch { /* fail closed */ }
        }
        if (typeof owner !== 'string' || !owner) return json({ error: 'Unauthorized' }, 401)
        const match = url.pathname.match(/^\/api\/rooms\/([a-f0-9]{64})\/(ice\/[a-zA-Z0-9_-]{1,80}|join|sessions\/[^/]+(?:\/(?:pull|publish|renew|signal))?)$/)
        // Only the actual cleanup routes are exempt from the pause and API budget.
        // Authentication above and room ownership checks below remain mandatory.
        const iceCancellation = request.method === 'DELETE' && match?.[2].startsWith('ice/') === true
        const cleanup = iceCancellation || (request.method === 'DELETE' && match !== null && /^sessions\/[^/]+$/.test(match[2]))
        if (!cleanup && env.SERVICE_ENABLED !== 'true') return json({ error: 'Service paused' }, 503)
        if (!iceCancellation && (!env.CLOUDFLARE_SFU_APP_ID || !env.CLOUDFLARE_SFU_APP_SECRET)) {
            return json({ error: 'SFU is not configured' }, 503)
        }
        const headers = new Headers(request.headers)
        headers.delete('Authorization'); headers.set('X-Owner', owner)
        headers.delete('X-User'); if (device) headers.set('X-User', device.accountID)
        const isStatus = url.pathname === '/api/status' && request.method === 'GET'
        if (!isStatus && !match) return json({ error: 'Invalid route or room capability' }, 400)
        if (!cleanup) {
            const limited = await limitCallAPI(env, device ? `account:${device.accountID}` : `owner:${owner}`)
            if (limited) return limited
        }
        if (isStatus) return env.USAGE_GUARD.get(env.USAGE_GUARD.idFromName('global')).fetch(new Request('https://internal/status'))
        if (!match) return json({ error: 'Invalid route or room capability' }, 400)
        return env.SIGNALING_ROOM.get(env.SIGNALING_ROOM.idFromName(match[1])).fetch(new Request(request, { headers }))
    }
}

// Approximate per-location abuse protection, not a billing or media-byte cap.
async function limitCallAPI(env: Env, key: string): Promise<Response | null> {
    try {
        if (env.CALL_API_LIMIT && (await env.CALL_API_LIMIT.limit({ key })).success) return null
        if (env.CALL_API_LIMIT) {
            const response = json({ code: 'api_rate_limited', error: 'Too many call service requests. Retry after 60 seconds.' }, 429)
            response.headers.set('Retry-After', '60')
            return response
        }
    } catch { /* An unavailable limiter must not silently admit new work. */ }
    const response = json({ code: 'api_rate_limit_unavailable', error: 'Call service request limit is unavailable. Retry after 60 seconds.' }, 503)
    response.headers.set('Retry-After', '60')
    return response
}
