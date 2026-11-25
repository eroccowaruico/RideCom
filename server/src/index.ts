import { SignalingRoom } from './SignalingRoom'
import { UsageGuard } from './UsageGuard'
import { type Env, json, sfuConfigured } from './types'
import { accountRequest, authenticateDevice } from './AppleAccount'
import { notificationRequest } from './Notifications'
import { contactDeletionRequest } from './ContactDeletions'
import { directRestoreDevicePath, directRestoreDeviceRequest } from './DirectRestoreDevices'
import { directRestoreRelayPath, directRestoreRelayRequest } from './DirectRestoreRelay'
import { ordinaryGroupReplyPrefix, ordinaryGroupReplyRequest } from './OrdinaryGroupReplies'
import { previewMediaTrialOwner, previewMediaTrialPrefix } from './PreviewMediaTrial'
import { sandboxAPNSProbe, sandboxAPNSProbePath } from './PreviewSandboxAPNSProbe'
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
        if (url.pathname === sandboxAPNSProbePath) return sandboxAPNSProbe(request, url, env)
        if (url.pathname.startsWith('/api/notifications/')) return notificationRequest(request, env)
        if (url.pathname.startsWith(ordinaryGroupReplyPrefix)) return ordinaryGroupReplyRequest(request, env)
        if (url.pathname === directRestoreRelayPath) return directRestoreRelayRequest(request, url, env)
        if (url.pathname === directRestoreDevicePath) return directRestoreDeviceRequest(request, url, env)
        if (url.pathname === '/api/contact-deletions' || url.pathname.startsWith('/api/contact-deletions/')) {
            return contactDeletionRequest(request, env)
        }
        if (url.pathname.startsWith('/api/auth/')) return accountRequest(request, env)
        // Every billable operation is behind a per-device credential. No shared application secret in clients.
        const authorization = request.headers.get('Authorization') ?? ''
        if (!authorization.startsWith('Bearer ') || authorization.length > 512) return json({ error: 'Unauthorized' }, 401)
        const credential = authorization.slice(7)
        const match = url.pathname.match(/^\/api\/rooms\/([a-f0-9]{64})\/(ice\/[a-zA-Z0-9_-]{1,80}|join|sessions\/[^/]+(?:\/(?:pull|publish|renew|signal))?)$/)
        const roomID = match && env.SIGNALING_ROOM.idFromName(match[1])
        const sessionAction = match?.[2].match(/^sessions\/([^/]+)(\/renew)?$/)
        const permitsCallRenewal = sessionAction && (
            (request.method === 'POST' && sessionAction[2] === '/renew')
            || (request.method === 'DELETE' && sessionAction[2] === undefined))
        let device: Awaited<ReturnType<typeof authenticateDevice>>
        try {
            const call = roomID && permitsCallRenewal ? { roomID: roomID.toString(), sessionID: sessionAction[1] } : undefined
            device = await authenticateDevice(credential, env, call)
        }
        catch { return json({ error: 'Account service unavailable' }, 503) }
        let owner: string | undefined
        if (device) owner = `${device.userID}:${device.deviceID}`
        else if (credential.startsWith(previewMediaTrialPrefix)) {
            owner = await previewMediaTrialOwner(request, url, credential, env.TEST_PREVIEW_MEDIA_TRIAL, match?.[1], match?.[2])
        }
        if (typeof owner !== 'string' || !owner) return json({ error: 'Unauthorized' }, 401)
        // Only the actual cleanup routes are exempt from the pause and API budget.
        // Authentication above and room ownership checks below remain mandatory.
        const iceCancellation = request.method === 'DELETE' && match?.[2].startsWith('ice/') === true
        const cleanup = iceCancellation || (request.method === 'DELETE' && match !== null && /^sessions\/[^/]+$/.test(match[2]))
        if (!cleanup && env.SERVICE_ENABLED !== 'true') {
            return json({ code: 'call_service_paused', error: 'Service paused' }, 503)
        }
        if (!iceCancellation && !sfuConfigured(env)) {
            return json({ error: 'SFU is not configured' }, 503)
        }
        const headers = new Headers(request.headers)
        headers.delete('Authorization'); headers.set('X-Owner', owner)
        headers.delete('X-User'); if (device) headers.set('X-User', device.accountID)
        headers.delete('X-Device-Token-Hash')
        if (device && !device.continuing && match?.[2].endsWith('/publish')) {
            headers.set('X-Device-Token-Hash', device.tokenHash)
        }
        headers.delete('X-Call-Renewal')
        if (device?.continuing) headers.set('X-Call-Renewal', '1')
        const isStatus = url.pathname === '/api/status' && request.method === 'GET'
        if (!isStatus && !match) return json({ error: 'Invalid route or room capability' }, 400)
        if (!cleanup) {
            const limited = await limitCallAPI(env, device ? `account:${device.accountID}` : `owner:${owner}`)
            if (limited) return limited
        }
        if (isStatus) return env.USAGE_GUARD.get(env.USAGE_GUARD.idFromName('global')).fetch(new Request('https://internal/status'))
        if (!roomID) return json({ error: 'Invalid route or room capability' }, 400)
        return env.SIGNALING_ROOM.get(roomID).fetch(new Request(request, { headers }))
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
