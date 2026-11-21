import { verifyDeviceProof } from './DeviceIdentity'
import { publicAccountIndex } from './NotificationIndex'
import { readJSON, type Env } from './types'

const hex = /^[a-f0-9]{64}$/
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const base64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/
const fields = ['senderUserID', 'deviceID', 'sessionBinding', 'submission', 'proof']

type Purpose = 'submitBackgroundGroupInvitation' | 'cancelBackgroundGroupInvitation'
    | 'submitBackgroundContactInvitationAcceptance'

export async function authenticateBackgroundSubmission(request: Request, origin: string, purpose: Purpose, env: Env) {
    const body: Record<string, unknown> = await readJSON(request)
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

    let value: Record<string, unknown>
    try {
        value = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })
            .decode(Uint8Array.from(atob(submission), character => character.charCodeAt(0))))
    } catch { throw new Error('body') }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('body')

    const route = await publicAccountIndex(env, senderUserID).current()
    if (route?.userID !== senderUserID) return null
    const owner = env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(route.accountID))
    const auth = await owner.authenticateBoundSession(senderUserID, deviceID, sessionBinding)
    return auth ? { auth, body: value } : null
}
