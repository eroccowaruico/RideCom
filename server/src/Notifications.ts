import { importJWK, jwtVerify, SignJWT } from 'jose'
import { notificationAuth } from './AppleAccount'
import { callLifetime, dedupeLifetime, groupInvitationLifetime, type NotificationAuth, type NotificationCall, type NotificationDevice, type DeliveryStatus } from './AccountNotifications'
import { verifyDeviceProof } from './DeviceIdentity'
import { deliverNotification, notificationProviderToken, notificationsConfigured } from './NotificationDelivery'
import { json, readJSON, type Env } from './types'

const publicIDPattern = /^[a-f0-9]{64}$/
const uuidPattern = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i
const audience = 'rideintercom-call-notification'
const groupAudience = 'rideintercom-group-invitation'
const account = (env: Env, id: string) => env.USER_ACCOUNT.get(env.USER_ACCOUNT.idFromString(id))
const index = (env: Env, name: string) => env.NOTIFICATION_INDEX.get(env.NOTIFICATION_INDEX.idFromName(name))
export const notificationHash = async (value: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), b => b.toString(16).padStart(2, '0')).join('')
function fields(body: Record<string, unknown>, allowed: string[]) {
    if (Object.keys(body).some(key => !allowed.includes(key))) throw new Error('body')
}
async function capabilityKey(env: Env, signing: boolean) {
    const jwk = JSON.parse(env.DEVICE_IDENTITY_SIGNING_KEY!)
    if (jwk.kty !== 'EC' || jwk.crv !== 'P-256' || !jwk.d) throw new Error('configuration')
    return importJWK(signing ? jwk : { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y }, 'ES256')
}
async function readCapability(value: unknown, env: Env, issuer: string, senderID: string, requiredAudience = audience) {
    if (typeof value !== 'string' || value.length > 4096) return null
    try {
        const { payload, protectedHeader } = await jwtVerify(value, await capabilityKey(env, false), {
            issuer, audience: requiredAudience, algorithms: ['ES256'], requiredClaims: ['sub', 'iat', 'jti', 'recipient']
        })
        if (protectedHeader.typ !== 'rideintercom-notification+jwt' || payload.sub !== senderID
            || typeof payload.recipient !== 'string' || !publicIDPattern.test(payload.recipient)
            || typeof payload.jti !== 'string' || !uuidPattern.test(payload.jti)
            || typeof payload.iat !== 'number' || payload.iat > Date.now() / 1000 + 60) return null
        return { recipient: payload.recipient, grantHash: await notificationHash(payload.jti) }
    } catch { return null }
}
async function target(env: Env, userID: string) {
    const route = await index(env, 'user:' + userID).current()
    return route?.userID === userID ? account(env, route.accountID) : null
}
async function publishRoute(env: Env, auth: NotificationAuth, expiresAt: number) {
    await index(env, 'user:' + auth.userID).bind({ accountID: auth.accountID, userID: auth.userID, expiresAt })
}
const callReply = (call: NotificationCall) => ({ requestID: call.requestID, expiresAt: call.expiresAt, status: call.status })

export async function notificationRequest(request: Request, env: Env): Promise<Response> {
    try {
        const url = new URL(request.url), path = url.pathname, method = request.method
        const bearer = request.headers.get('Authorization') ?? ''
        const auth = bearer.startsWith('Bearer ') && bearer.length <= 512 ? await notificationAuth(bearer.slice(7), env) : null
        if (!auth) return json({ error: 'Unauthorized' }, 401)
        const owner = account(env, auth.accountID)
        // Revocation remains available even when delivery is disabled or misconfigured.
        if (path === '/api/notifications/device' && method === 'DELETE') {
            const previous = await owner.notificationRemoveDevice(auth)
            if (previous) await index(env, previous.tokenIndex).remove(auth.accountID, auth.userID, previous.registrationID)
            return json({})
        }
        const grantDelete = path.match(/^\/api\/notifications\/grants(?:\/([a-f0-9-]{36}))?$/i)
        if (grantDelete && method === 'DELETE') {
            if (grantDelete[1] && !uuidPattern.test(grantDelete[1])) throw new Error('body')
            const ok = await owner.notificationRevokeGrant(auth, grantDelete[1] ? await notificationHash(grantDelete[1].toLowerCase()) : undefined)
            return ok ? json({}) : json({ error: 'Unauthorized' }, 401)
        }
        const route = path.match(/^\/api\/notifications\/calls\/([a-f0-9]{64})\/([a-f0-9-]{36})$/i)
        if (route && uuidPattern.test(route[2]) && ['GET', 'DELETE'].includes(method)) {
            route[1] = route[1].toLowerCase(); route[2] = route[2].toLowerCase()
            const receiver = await target(env, route[1])
            if (!receiver || !await owner.notificationAuthorized(auth)) return json({ error: 'Not found' }, 404)
            if (method === 'DELETE') return await receiver.notificationCancel(route[1], route[2], auth.userID) ? json({}) : json({ error: 'Not found' }, 404)
            if (route[1] !== auth.userID) return json({ error: 'Not found' }, 404)
            const call = await receiver.notificationGet(route[1], route[2])
            if (!call) return json({ error: 'Not found' }, 404)
            if (call.expiresAt <= Date.now() || call.status === 'cancelled'
                || !await receiver.notificationGrantActive(route[1], call.grantHash)
                || !await account(env, call.sender.accountID).notificationAuthorized(call.sender)) return json({ error: 'Call request expired' }, 410)
            if (!await owner.notificationAuthorized(auth)) return json({ error: 'Not found' }, 404)
            return json({ ...callReply(call), senderUserID: call.sender.userID })
        }
        const devicesRoute = path.match(/^\/api\/notifications\/group-invitations\/([a-f0-9]{64})\/([a-f0-9-]{36})\/additional-devices$/i)
        if (devicesRoute && uuidPattern.test(devicesRoute[2])) {
            const recipient = devicesRoute[1].toLowerCase(), id = devicesRoute[2].toLowerCase()
            const notFound = () => json({ error: 'Not found' }, 404)
            if (method === 'POST') {
                if (auth.userID !== recipient) return notFound()
                if (!notificationsConfigured(env)) return json({ error: 'Notifications are unavailable' }, 503)
                const invitation = await owner.groupInvitationGet(recipient, id)
                if (!invitation || invitation.status === 'cancelled' || invitation.additionalDevicesClosed
                    || !await owner.notificationGrantActive(recipient, invitation.grantHash)) return notFound()
                if (!await owner.notificationMutationBudget(auth)) return json({ error: 'Too many notification changes' }, 429)
                const address = await verifyDeviceProof(auth, url.origin, 'requestGroupInvitationRedelivery', id, await readJSON(request), env)
                if (!address) return json({ error: 'Device proof required' }, 403)
                return await owner.groupInvitationAddDevice(auth, id, address) ? json({}) : notFound()
            }
            if (method === 'GET') {
                const receiver = await target(env, recipient)
                const devices = await receiver?.groupInvitationDevices(auth, recipient, id)
                if (!devices || await owner.groupInvitationSenderState(auth, recipient, id) !== 'active') return notFound()
                return json({ devices })
            }
            return json({ error: 'Method not allowed' }, 405)
        }
        const groupRoute = path.match(/^\/api\/notifications\/group-invitations\/([a-f0-9]{64})\/([a-f0-9-]{36})$/i)
        if (groupRoute && uuidPattern.test(groupRoute[2]) && ['GET', 'DELETE'].includes(method)) {
            const recipient = groupRoute[1].toLowerCase(), id = groupRoute[2].toLowerCase(), receiver = await target(env, recipient)
            const value = await receiver?.groupInvitationGet(recipient, id)
            if (!value) {
                if (method !== 'DELETE' || auth.userID === recipient) return json({ error: 'Not found' }, 404)
                const result = await owner.groupInvitationCancelUnstored(auth, recipient, id)
                if (result === 'limited') return json({ error: 'Too many pending cancellations' }, 429)
                // Also finish a packet inserted between the first lookup and the sender's cancellation.
                if (result === 'cancelled') {
                    const status = await receiver?.groupInvitationFinish(recipient, id, auth.userID)
                    if (status) return json({ status })
                }
                return json({ error: 'Not found' }, 404)
            }
            if (!await owner.notificationAuthorized(auth) || (auth.userID !== recipient && auth.userID !== value.sender.userID)) return json({ error: 'Not found' }, 404)
            if (method === 'DELETE') {
                const status = await receiver!.groupInvitationFinish(recipient, id, auth.userID, url.searchParams.get('discard') === '1')
                return status ? json({ status }) : json({ error: 'Not found' }, 404)
            }
            return json({ requestID: id, expiresAt: value.expiresAt, status: value.status })
        }
        if (path === '/api/notifications/group-invitations' && method === 'GET') {
            const key = url.searchParams.get('recipientKey') ?? ''
            if (!/^[A-Za-z0-9_-]{87}$/.test(key)) throw new Error('body')
            const pending = await owner.groupInvitationPending(auth.userID, key)
            for (const { requestID, sender } of pending) {
                const state = await account(env, sender.accountID).groupInvitationSenderState(sender, auth.userID, requestID)
                if (state === 'cancelled') await owner.groupInvitationFinish(auth.userID, requestID, sender.userID)
                if (state !== 'active') continue
                const delivery = await owner.groupInvitationDelivery(auth, key, requestID, sender)
                if (delivery === 'unauthorized') break
                if (delivery) return json({ delivery })
            }
            return json({ delivery: null })
        }
        if (!notificationsConfigured(env)) return json({ error: 'Notifications are unavailable', code: 'notifications_unavailable' }, 503)
        if (path === '/api/notifications/device' && method === 'PUT') {
            const body = await readJSON(request); fields(body, ['token', 'environment', 'topic'])
            if (typeof body.token !== 'string' || !/^(?:[a-f0-9]{2}){1,2048}$/i.test(body.token)
                || body.environment !== env.APNS_ENVIRONMENT || body.topic !== env.APNS_TOPIC) throw new Error('body')
            const session = await owner.authenticate(auth.deviceID, auth.tokenHash)
            if (!session || session.userID !== auth.userID) return json({ error: 'Unauthorized' }, 401)
            if (!await owner.notificationMutationBudget(auth)) return json({ error: 'Too many notification changes' }, 429)
            const registrationID = crypto.randomUUID()
            const tokenIndex = 'token:' + await notificationHash(`${body.environment}|${body.topic}|${body.token.toLowerCase()}`)
            // Index first. A later ownership transfer invalidates this registration even if its response is delayed.
            await index(env, tokenIndex).bind({ accountID: auth.accountID, userID: auth.userID, deviceID: auth.deviceID, registrationID, expiresAt: session.expiresAt })
            const device: NotificationDevice = { token: body.token.toLowerCase(), environment: body.environment, topic: body.topic,
                registrationID, tokenIndex, deviceID: auth.deviceID, tokenHash: auth.tokenHash, expiresAt: session.expiresAt }
            const registered = await owner.notificationRegister(auth, device)
            if (!registered) {
                await index(env, tokenIndex).remove(auth.accountID, auth.userID, registrationID)
                return json({ error: 'Unauthorized' }, 401)
            }
            if (registered.previous && registered.previous.registrationID !== registrationID) {
                await index(env, registered.previous.tokenIndex).remove(auth.accountID, auth.userID, registered.previous.registrationID)
            }
            await publishRoute(env, auth, session.expiresAt)
            if (!await owner.notificationAuthorized(auth)) return json({ error: 'Unauthorized' }, 401)
            return json({ registered: true })
        }
        if (['/api/notifications/grants', '/api/notifications/group-invitations/grants'].includes(path) && method === 'POST') {
            const body = await readJSON(request); fields(body, ['senderUserID'])
            if (typeof body.senderUserID !== 'string' || !publicIDPattern.test(body.senderUserID) || body.senderUserID === auth.userID) throw new Error('body')
            if (!await owner.notificationMutationBudget(auth)) return json({ error: 'Too many notification changes' }, 429)
            const grantID = crypto.randomUUID()
            const capability = await new SignJWT({ recipient: auth.userID }).setProtectedHeader({ alg: 'ES256', typ: 'rideintercom-notification+jwt' })
                .setIssuer(url.origin).setAudience(path.includes('/group-invitations/') ? groupAudience : audience).setSubject(body.senderUserID).setIssuedAt().setJti(grantID).sign(await capabilityKey(env, true))
            if (!await owner.notificationActivateGrant(auth, await notificationHash(grantID))) return json({ error: 'Permission limit or inactive account', code: 'grant_limit_or_inactive' }, 409)
            const session = await owner.authenticate(auth.deviceID, auth.tokenHash)
            if (!session || session.userID !== auth.userID) return json({ error: 'Unauthorized' }, 401)
            await publishRoute(env, auth, session.expiresAt)
            return json({ grantID, capability })
        }
        if (path === '/api/notifications/group-invitations' && method === 'POST') {
            const body = await readJSON(request); fields(body, ['capability', 'requestID', 'noticeID', 'expiresAt', 'recipientKey', 'envelope'])
            const now = Date.now()
            if (typeof body.requestID !== 'string' || !uuidPattern.test(body.requestID)
                || (body.noticeID !== undefined && (typeof body.noticeID !== 'string' || !uuidPattern.test(body.noticeID)))
                || typeof body.expiresAt !== 'number' || !Number.isFinite(body.expiresAt) || body.expiresAt <= now || body.expiresAt > now + groupInvitationLifetime
                || typeof body.recipientKey !== 'string' || !/^[A-Za-z0-9_-]{87}$/.test(body.recipientKey)
                || typeof body.envelope !== 'string' || body.envelope.length < 4 || body.envelope.length > 21848
                || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(body.envelope)) throw new Error('body')
            const grant = await readCapability(body.capability, env, url.origin, auth.userID, groupAudience)
            if (!grant) return json({ error: 'Invitation permission required' }, 403)
            const receiver = await target(env, grant.recipient)
            if (!receiver || !await receiver.notificationGrantActive(grant.recipient, grant.grantHash)) return json({ error: 'Invitation permission required' }, 403)
            const id = body.requestID.toLowerCase()
            const cancelled = () => json({ requestID: id, expiresAt: body.expiresAt, status: 'cancelled' })
            const permission = await owner.groupInvitationSendBudget(auth, grant.recipient, id)
            if (permission === 'cancelled') return cancelled()
            if (permission !== 'active') return json({ error: 'Too many invitations' }, 429)
            const started = await receiver.groupInvitationBegin({ requestID: id, sender: auth, recipientID: grant.recipient, grantHash: grant.grantHash,
                recipientKey: body.recipientKey, noticeID: (body.noticeID ?? body.requestID).toLowerCase(), envelope: body.envelope, expiresAt: body.expiresAt, status: 'queued' })
            if (started === 'forbidden') return json({ error: 'Invitation permission required' }, 403)
            if (started === 'conflict') return json({ error: 'Invitation ID already used' }, 409)
            if (started === 'limited') return json({ error: 'Too many invitations' }, 429)
            if (started === 'expired') return json({ error: 'Invitation expired' }, 400)
            if (await owner.groupInvitationSenderState(auth, grant.recipient, id) === 'cancelled') {
                await receiver.groupInvitationFinish(grant.recipient, id, auth.userID)
                return cancelled()
            }
            if (started === 'notify') {
                const candidates = await receiver.groupInvitationCandidates(grant.recipient, id)
                if (candidates.length) {
                    const providerToken = await notificationProviderToken(env)
                    for (const device of candidates) {
                        const binding = await index(env, device.tokenIndex).current()
                        if (binding?.registrationID !== device.registrationID || binding.userID !== grant.recipient) continue
                        if (await owner.groupInvitationSenderState(auth, grant.recipient, id) !== 'active') break
                        if (!(await receiver.groupInvitationCandidates(grant.recipient, id)).some(v => v.deviceID === device.deviceID && v.registrationID === device.registrationID)) continue
                        const result = await deliverNotification(device, providerToken, id, grant.recipient, body.expiresAt, 'groupInvitation')
                        if (result === 'invalid_token') await receiver.notificationInvalidToken(grant.recipient, device.deviceID, device.registrationID)
                    }
                }
            }
            const value = await receiver.groupInvitationGet(grant.recipient, id)
            return value ? json({ requestID: id, expiresAt: value.expiresAt, status: value.status }) : json({ error: 'Not found' }, 404)
        }
        if (path === '/api/notifications/calls' && method === 'POST') {
            const body = await readJSON(request); fields(body, ['capability', 'requestID'])
            if (typeof body.requestID !== 'string' || !uuidPattern.test(body.requestID)) throw new Error('body')
            const requestID = body.requestID.toLowerCase()
            const grant = await readCapability(body.capability, env, url.origin, auth.userID)
            if (!grant) return json({ error: 'Notification permission required' }, 403)
            const receiver = await target(env, grant.recipient)
            if (!receiver || !await receiver.notificationGrantActive(grant.recipient, grant.grantHash)) return json({ error: 'Notification permission required' }, 403)
            if (!await owner.notificationSendBudget(auth)) return json({ error: 'Too many call requests' }, 429)
            const now = Date.now()
            const started = await receiver.notificationBegin({ requestID, sender: auth, recipientID: grant.recipient,
                grantHash: grant.grantHash, expiresAt: now + callLifetime, forgetAt: now + dedupeLifetime, status: 'processing' })
            if (started === 'forbidden') return json({ error: 'Notification permission required' }, 403)
            if (started === 'limited') return json({ error: 'Too many call requests' }, 429)
            if (!started.fresh) return json(callReply(started.call))
            const candidates = await receiver.notificationCandidates(grant.recipient, requestID)
            let status: DeliveryStatus = 'no_destinations'
            if (candidates.length) {
                const providerToken = await notificationProviderToken(env)
                for (const device of candidates) {
                    const binding = await index(env, device.tokenIndex).current()
                    if (binding?.registrationID !== device.registrationID || binding.userID !== grant.recipient) continue
                    if (!await owner.notificationAuthorized(auth)
                        || !await receiver.notificationDeliveryCurrent(grant.recipient, requestID, device.deviceID, device.registrationID)) continue
                    const delivered = await deliverNotification(device, providerToken, requestID, grant.recipient, started.call.expiresAt)
                    if (delivered === 'invalid_token') {
                        await receiver.notificationInvalidToken(grant.recipient, device.deviceID, device.registrationID)
                        await index(env, device.tokenIndex).remove(binding.accountID, binding.userID, device.registrationID)
                    }
                    if (delivered === 'accepted') status = 'accepted'
                    else if (status !== 'accepted' && delivered === 'retry_later') status = 'retry_later'
                    else if (status === 'no_destinations') status = 'rejected'
                }
            }
            await receiver.notificationFinish(grant.recipient, requestID, status)
            return json(callReply(await receiver.notificationGet(grant.recipient, requestID) ?? { ...started.call, status: 'cancelled' }))
        }
        return json({ error: 'Not found' }, 404)
    } catch (error) {
        return error instanceof Error && error.message === 'body' ? json({ error: 'Invalid body' }, 400)
            : json({ error: 'Notifications are unavailable', code: 'notifications_unavailable' }, 503)
    }
}
