import { tracing } from 'cloudflare:workers'
import { importPKCS8, SignJWT } from 'jose'
import type { Env } from './types'
import type { NotificationDevice } from './AccountNotifications'

type NotificationProvider = {
    privateKey: string
    keyID: string
    teamID: string
    signingKey: Promise<CryptoKey>
    credential?: { issuedAt: number; token: Promise<string> }
}

// Cache one provider configuration per isolate. It contains no user or request state.
let cachedProvider: NotificationProvider | undefined
function notificationProvider(env: Env): NotificationProvider | null {
    const { APNS_PRIVATE_KEY: privateKey, APNS_KEY_ID: keyID, APPLE_TEAM_ID: teamID } = env
    if (!privateKey || !keyID || !teamID) return null
    if (cachedProvider?.privateKey === privateKey && cachedProvider.keyID === keyID
        && cachedProvider.teamID === teamID) return cachedProvider
    cachedProvider = { privateKey, keyID, teamID, signingKey: importPKCS8(privateKey, 'ES256') }
    return cachedProvider
}

export async function readyAPNSEnvironment(env: Env): Promise<NotificationDevice['environment'] | null> {
    const environment = env.APNS_ENVIRONMENT
    if (env.NOTIFICATIONS_ENABLED !== 'true' || !env.APNS_TOPIC
        || (environment !== 'sandbox' && environment !== 'production')) return null
    // An automatic fetch span can retain the APNs device token in the URL path.
    if (environment === 'sandbox' && tracing.getActiveSpan()?.isTraced !== false) return null
    const provider = notificationProvider(env)
    if (!provider) return null
    try {
        await provider.signingKey
        return environment
    } catch {
        if (cachedProvider === provider) cachedProvider = undefined
        return null
    }
}

export async function notificationProviderToken(env: Env): Promise<string> {
    const provider = notificationProvider(env)
    if (!provider) throw new Error('Notifications are unavailable')
    const key = await provider.signingKey
    const issuedAt = Math.floor(Date.now() / 1000)
    const previous = provider.credential
    if (previous && issuedAt >= previous.issuedAt && issuedAt - previous.issuedAt < 50 * 60) return previous.token
    const token = new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: provider.keyID })
        .setIssuer(provider.teamID).setIssuedAt(issuedAt).sign(key)
    const entry = { issuedAt, token }
    provider.credential = entry
    try { return await entry.token }
    catch (error) { if (provider.credential === entry) provider.credential = undefined; throw error }
}

export type NotificationDeliveryResult = 'accepted' | 'invalid_token' | 'retry_later' | 'rejected'
export type NotificationKind = 'call' | 'groupInvitation'
/** Native fetch is the production candidate; tests intercept it before any external I/O. */
export async function deliverNotification(device: NotificationDevice, providerToken: string,
                                        requestID: string, recipientID: string, expiresAt: number,
                                        kind: NotificationKind = 'call'): Promise<NotificationDeliveryResult> {
    const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com'
    try {
        const response = await fetch(`https://${host}/3/device/${device.token}`, {
            method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(8000),
            headers: { authorization: `bearer ${providerToken}`, 'content-type': 'application/json',
                'apns-topic': device.topic, 'apns-push-type': 'alert', 'apns-priority': '10',
                'apns-id': requestID, 'apns-collapse-id': requestID, 'apns-expiration': String(Math.floor(expiresAt / 1000)) },
            body: JSON.stringify(kind === 'groupInvitation'
                ? { aps: {
                        alert: { 'title-loc-key': 'GROUP_INVITATION_TITLE', 'loc-key': 'GROUP_INVITATION_BODY' },
                        category: 'RIDEINTERCOM_GROUP_INVITATION',
                        'interruption-level': 'passive',
                    },
                    version: 1, kind, requestID, recipientID }
                : { aps: { alert: { 'title-loc-key': 'CALL_REQUEST_TITLE', 'loc-key': 'CALL_REQUEST_BODY' }, sound: 'default', category: 'RIDEINTERCOM_CALL_REQUEST' },
                    version: 1, requestID, recipientID })
        })
        // No provider body, token or payload is logged or forwarded to callers.
        await response.body?.cancel()
        if (response.status === 200) return 'accepted'
        if (response.status === 410) return 'invalid_token'
        if (response.status === 429 || response.status >= 500) return 'retry_later'
        return 'rejected'
    } catch { return 'retry_later' }
}
