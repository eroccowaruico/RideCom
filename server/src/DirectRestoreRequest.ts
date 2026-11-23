import type { NotificationAuth } from './AccountNotifications'
import { notificationAuth } from './AppleAccount'
import { json, type Env } from './types'

type RestoreAdmissionPolicy = {
    methods: readonly string[]
    rateScope: 'direct-restore' | 'direct-restore-device'
}

export const restoreMissing = () => json({ error: 'Not found' }, 404)
export const restoreUnauthorized = () => json({ error: 'Unauthorized' }, 401)

export async function withDirectRestoreRequest(
    request: Request, env: Env, policy: RestoreAdmissionPolicy,
    operation: (auth: NotificationAuth) => Promise<Response>,
): Promise<Response> {
    if (env.DIRECT_CALL_RESTORE_RELAY_ENABLED !== 'true') return restoreMissing()
    if (!policy.methods.includes(request.method)) return json({ error: 'Method not allowed' }, 405)
    try {
        const bearer = request.headers.get('Authorization') ?? ''
        const auth = bearer.startsWith('Bearer ') && bearer.length <= 512
            ? await notificationAuth(bearer.slice(7), env) : null
        if (!auth) return restoreUnauthorized()
        if (!(await env.CALL_API_LIMIT.limit({ key: `${policy.rateScope}:${auth.accountID}` })).success) {
            return json({ error: 'Too many restore requests' }, 429)
        }
        return await operation(auth)
    } catch (error) {
        return error instanceof Error && error.message === 'body'
            ? json({ error: 'Invalid restore request' }, 400) : json({ error: 'Restore delivery unavailable' }, 503)
    }
}
