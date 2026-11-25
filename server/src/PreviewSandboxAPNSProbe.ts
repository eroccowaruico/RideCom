import { tracing } from 'cloudflare:workers'
import { notificationProviderToken } from './NotificationDelivery'
import { sandboxTransportReady, sendViaSandboxTransport } from './SandboxAPNSTransport'
import { isRecord, json, readJSON, sha256Hex, type Env } from './types'

export const sandboxAPNSProbePath = '/api/test/sandbox-apns'
const fixedPreview = 'https://preview-ridecom.analog.workers.dev'
const lifetime = 20 * 60 * 1000
const digestPattern = /^[a-f0-9]{64}$/

function readGrant(configuration: string | undefined) {
    if (!configuration) return null
    try {
        const value: unknown = JSON.parse(configuration)
        if (!isRecord(value)) return null
        const { credentialDigest, destinationDigest, issuedAt, expiresAt } = value
        const now = Date.now()
        if (typeof credentialDigest !== 'string' || !digestPattern.test(credentialDigest)
            || typeof destinationDigest !== 'string' || !digestPattern.test(destinationDigest)
            || typeof issuedAt !== 'number' || !Number.isSafeInteger(issuedAt)
            || typeof expiresAt !== 'number' || !Number.isSafeInteger(expiresAt)
            || now < issuedAt || now >= expiresAt || expiresAt - issuedAt > lifetime) return null
        return { credentialDigest, destinationDigest, expiresAt }
    } catch { return null }
}

export async function sandboxAPNSProbe(request: Request, url: URL, env: Env): Promise<Response> {
    const notFound = () => json({ error: 'Not found' }, 404)
    if (url.origin !== fixedPreview || request.method !== 'POST' || env.APNS_ENVIRONMENT !== 'sandbox') return notFound()
    const grant = readGrant(env.TEST_PREVIEW_SANDBOX_APNS_PROBE)
    if (!grant || !env.APNS_TOPIC) return notFound()
    const unauthorized = () => json({ error: 'Unauthorized' }, 401)
    const authorization = request.headers.get('Authorization') ?? ''
    if (!/^Bearer preview-apns\.[a-zA-Z0-9_-]{43}$/.test(authorization)
        || await sha256Hex(authorization.slice(7)) !== grant.credentialDigest) return unauthorized()
    let body: Record<string, unknown>
    try { body = await readJSON(request) } catch { return unauthorized() }
    const token = body.token
    if (Object.keys(body).length !== 1 || typeof token !== 'string' || !/^(?:[a-f0-9]{2}){1,2048}$/.test(token)
        || await sha256Hex(token) !== grant.destinationDigest) return unauthorized()

    const unavailable = () => json({ error: 'Sandbox APNs unavailable' }, 503)
    try {
        if (!await sandboxTransportReady(env)) return unavailable()
        const providerToken = await notificationProviderToken(env)
        const claim = env.NOTIFICATION_INDEX.getByName(`sandbox-apns-probe:${grant.credentialDigest}`)
        if (!await claim.claimSandboxProbe(grant.expiresAt)) return json({ error: 'Probe already used or expired' }, 409)
        if (Date.now() >= grant.expiresAt) return notFound()
        const delivery = await sendViaSandboxTransport(env, token, {
            authorization: `bearer ${providerToken}`, 'content-type': 'application/json',
            'apns-topic': env.APNS_TOPIC, 'apns-push-type': 'alert', 'apns-priority': '10',
            'apns-expiration': '0', 'apns-id': crypto.randomUUID(),
        }, JSON.stringify({ aps: { alert: 'RideCom Sandbox test' } }))
        if (!delivery || delivery.status === 503) return unavailable()
        const response = json({ apnsStatus: delivery.status })
        const traceID = tracing.getActiveSpan()?.spanContext().traceId
        if (traceID && traceID !== '0'.repeat(32)) response.headers.set('X-RideCom-Probe-Trace-ID', traceID)
        return response
    } catch { return unavailable() }
}
