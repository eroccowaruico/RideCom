
export interface NotificationAuth { accountID: string; userID: string; deviceID: string; tokenHash: string }
export interface NotificationDevice {
    token: string; environment: 'sandbox' | 'production'; topic: string
    registrationID: string; tokenIndex: string; deviceID: string; tokenHash: string; expiresAt: number
}
export type DeliveryStatus = 'processing' | 'accepted' | 'no_destinations' | 'retry_later' | 'rejected' | 'cancelled'
export interface NotificationCall {
    requestID: string; sender: NotificationAuth; recipientID: string; grantHash: string
    expiresAt: number; forgetAt: number; status: DeliveryStatus
}
export const callLifetime = 120_000
export const dedupeLifetime = 86_400_000
export const groupInvitationLifetime = 7 * 86_400_000 + 300_000
const groupInvitationSyncLifetime = 28 * 86_400_000
const maxLiveGroupInvitations = 64
const maxStoredGroupInvitations = 512
const devicePrefix = 'notify-device:'
const grantPrefix = 'notify-grant:'
export interface InvitationDeviceAddress { memberID: string; recipientKey: string; expiresAt: number }
interface InvitationDeviceRequest extends InvitationDeviceAddress { auth: NotificationAuth }
export interface NotificationGroupInvitation {
    requestID: string; sender: NotificationAuth; recipientID: string; grantHash: string
    recipientKey: string; noticeID: string; envelope: string | null; expiresAt: number; status: 'queued' | 'received' | 'cancelled'
    retainUntil?: number
    sourceRequestID?: string
    recipientDeviceID?: string
    additionalDevicesClosed?: boolean
    additionalDevices?: InvitationDeviceRequest[]
}
interface GroupInvitationStatus {
    senderUserID: string; recipientDeviceID?: string; expiresAt: number
    status: NotificationGroupInvitation['status']
}
interface RetainedGroupInvitationResult extends GroupInvitationStatus {
    status: 'received' | 'cancelled'; retainUntil: number
}
const invitationPrefix = 'notify-group:'
const invitationResultPrefix = 'notify-group-result:'
const groupCancellationPrefix = 'notify-group-cancel:'
const callPrefix = 'notify-call:'

/** Shares the account's synchronous storage, so revocation/deletion wins locally. */
export class AccountNotifications {
    constructor(private readonly storage: DurableObjectStorage) {}
    isCurrent(userID: string): boolean { return this.storage.kv.get('userID') === userID }
    authorized(auth: NotificationAuth): boolean {
        const device = this.storage.kv.get<{ tokenHash: string; expiresAt: number }>(`device:${auth.deviceID}`)
        return this.isCurrent(auth.userID) && !!device && device.expiresAt > Date.now() && device.tokenHash === auth.tokenHash
    }
    register(auth: NotificationAuth, device: NotificationDevice): { previous: NotificationDevice | null } | null {
        if (!this.authorized(auth)) return null
        const previous = this.device(auth.deviceID)
        this.storage.kv.put(devicePrefix + auth.deviceID, device)
        return { previous }
    }
    removeDevice(auth: NotificationAuth): NotificationDevice | null {
        if (!this.authorized(auth)) return null
        const value = this.storage.kv.get<NotificationDevice>(devicePrefix + auth.deviceID) ?? null
        this.storage.kv.delete(devicePrefix + auth.deviceID)
        return value
    }
    device(deviceID: string): NotificationDevice | null { return this.storage.kv.get<NotificationDevice>(devicePrefix + deviceID) ?? null }
    devices(): NotificationDevice[] { return [...this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })].map(([, value]) => value) }
    takeMutationBudget(auth: NotificationAuth): boolean { return this.authorized(auth) && this.takeBudget('mutation', 60) }
    invalidateDevice(deviceID: string) { this.storage.kv.delete(devicePrefix + deviceID) }
    invalidateAll() {
        for (const prefix of [devicePrefix, grantPrefix, callPrefix, invitationPrefix, invitationResultPrefix, groupCancellationPrefix, 'notify-rate:']) {
            for (const [key] of this.storage.kv.list({ prefix })) this.storage.kv.delete(key)
        }
    }
    activateGrant(auth: NotificationAuth, hash: string): boolean {
        if (!this.authorized(auth)) return false
        if ([...this.storage.kv.list({ prefix: grantPrefix })].length >= 256) return false
        // Only the opaque hash is stored; the sender appears in the signed capability, not a contact table.
        this.storage.kv.put(grantPrefix + hash, true)
        return true
    }
    revokeGrant(auth: NotificationAuth, hash?: string): boolean {
        if (!this.authorized(auth)) return false
        if (hash) this.storage.kv.delete(grantPrefix + hash)
        else for (const [key] of this.storage.kv.list({ prefix: grantPrefix })) this.storage.kv.delete(key)
        return true
    }
    grantActive(userID: string, hash: string): boolean {
        return this.isCurrent(userID) && this.storage.kv.get(grantPrefix + hash) === true
    }
    takeSendBudget(auth: NotificationAuth): boolean {
        return this.authorized(auth) && this.takeBudget('sender', 60)
    }
    groupInvitationSenderState(auth: NotificationAuth, recipient: string, requestID: string): 'active' | 'inactive' | 'cancelled' {
        if (!this.authorized(auth)) return 'inactive'
        const expiresAt = this.storage.kv.get<number>(`${groupCancellationPrefix + recipient}:${requestID}`)
        return expiresAt !== undefined && expiresAt > Date.now() ? 'cancelled' : 'active'
    }
    takeGroupInvitationSendBudget(auth: NotificationAuth, recipient: string, requestID: string, background: boolean) {
        const state = this.groupInvitationSenderState(auth, recipient, requestID)
        if (state !== 'active') return state
        // A copied background submission cannot fill the shared budget with its one signed ID.
        return this.takeBudget('sender', 60, background ? `${recipient}:${requestID}` : undefined) ? 'active' : 'limited'
    }
    cancelUnstoredGroupInvitation(auth: NotificationAuth, recipient: string, requestID: string) {
        const state = this.groupInvitationSenderState(auth, recipient, requestID)
        if (state === 'inactive' || auth.userID === recipient) return 'unauthorized'
        if (state === 'cancelled') return 'cancelled'
        this.pruneUnstoredGroupCancellations()
        // Reserve only the authenticated sender's own storage, independent of the recipient inbox.
        if ([...this.storage.kv.list({ prefix: groupCancellationPrefix, limit: 512 })].length >= 512) return 'limited'
        this.storage.kv.put(`${groupCancellationPrefix + recipient}:${requestID}`, Date.now() + groupInvitationSyncLifetime)
        return 'cancelled'
    }
    private takeBudget(kind: string, maximum: number, groupDeliveryKey?: string): boolean {
        const key = `notify-rate:${kind}`, minute = Math.floor(Date.now() / 60_000)
        const stored = this.storage.kv.get<{ minute: number; count: number; groupDeliveryKeys?: string[] }>(key)
        const previous = stored?.minute === minute ? stored : undefined
        const count = previous?.count ?? 0
        const groupDeliveryKeys = previous?.groupDeliveryKeys ?? []
        if (groupDeliveryKey && groupDeliveryKeys.includes(groupDeliveryKey)) return true
        if (count >= maximum) return false
        if (groupDeliveryKey) groupDeliveryKeys.push(groupDeliveryKey)
        this.storage.kv.put(key, { minute, count: count + 1, groupDeliveryKeys })
        return true
    }
    begin(call: NotificationCall): { call: NotificationCall; fresh: boolean } | 'forbidden' | 'limited' {
        this.prune()
        if (!this.grantActive(call.recipientID, call.grantHash)) return 'forbidden'
        const old = this.storage.kv.get<NotificationCall>(callPrefix + call.requestID)
        if (old) return old.sender.userID === call.sender.userID && old.grantHash === call.grantHash ? { call: old, fresh: false } : 'forbidden'
        if (!this.takeBudget('recipient', 20) || [...this.storage.kv.list({ prefix: callPrefix })].length >= 512) return 'limited'
        this.storage.kv.put(callPrefix + call.requestID, call)
        return { call, fresh: true }
    }
    candidates(userID: string, requestID: string): NotificationDevice[] {
        if (!this.liveCall(userID, requestID)) return []
        return [...this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })].map(([, value]) => value)
            .filter(value => this.authorized({ accountID: '', userID, deviceID: value.deviceID, tokenHash: value.tokenHash }) && value.expiresAt > Date.now()).slice(0, 8)
    }
    liveCall(userID: string, requestID: string): NotificationCall | null {
        const call = this.storage.kv.get<NotificationCall>(callPrefix + requestID)
        return call && call.expiresAt > Date.now() && call.status !== 'cancelled'
            && this.grantActive(userID, call.grantHash) ? call : null
    }
    deliveryCurrent(userID: string, requestID: string, deviceID: string, registrationID: string): boolean {
        return this.candidates(userID, requestID).some(value => value.deviceID === deviceID && value.registrationID === registrationID)
    }
    finish(userID: string, requestID: string, status: DeliveryStatus): void {
        const call = this.liveCall(userID, requestID)
        if (call?.status === 'processing') this.storage.kv.put(callPrefix + requestID, { ...call, status })
    }
    invalidToken(userID: string, deviceID: string, registrationID: string): void {
        if (!this.isCurrent(userID)) return
        const current = this.storage.kv.get<NotificationDevice>(devicePrefix + deviceID)
        if (current?.registrationID === registrationID) this.storage.kv.delete(devicePrefix + deviceID)
    }
    get(userID: string, requestID: string): NotificationCall | null {
        return this.isCurrent(userID) ? this.storage.kv.get<NotificationCall>(callPrefix + requestID) ?? null : null
    }
    cancel(userID: string, requestID: string, senderID: string): boolean {
        const call = this.get(userID, requestID)
        if (!call || call.sender.userID !== senderID) return false
        this.storage.kv.put(callPrefix + requestID, { ...call, status: 'cancelled' })
        return true
    }
    beginInvitation(value: NotificationGroupInvitation): 'notify' | 'stored' | 'duplicate' | 'forbidden' | 'limited' | 'conflict' | 'expired' {
        this.prune()
        const now = Date.now()
        if (value.expiresAt <= now) return 'expired'
        if (!this.grantActive(value.recipientID, value.grantHash)) return 'forbidden'
        const address = value.sourceRequestID ? this.addressForRedelivery(value) : null
        if (value.sourceRequestID && !address) return 'forbidden'
        const old = this.storage.kv.get<NotificationGroupInvitation>(invitationPrefix + value.requestID)
        if (old) {
            if (old.sender.userID !== value.sender.userID || old.grantHash !== value.grantHash || old.recipientKey !== value.recipientKey || old.noticeID !== value.noticeID
                || old.sourceRequestID !== value.sourceRequestID || old.recipientDeviceID !== address?.auth.deviceID
                || old.expiresAt !== value.expiresAt || (old.envelope !== null && old.envelope !== value.envelope)) return 'conflict'
            // A current authenticated sender may resume its exact persisted packet after sign-in.
            // Merely retaining a packet from a signed-out credential cannot make it receivable.
            if (old.status === 'queued' && (old.sender.deviceID !== value.sender.deviceID || old.sender.tokenHash !== value.sender.tokenHash)) {
                this.storage.kv.put(invitationPrefix + value.requestID, { ...old, sender: value.sender })
                return 'stored'
            }
            return 'duplicate'
        }
        if (this.invitationResult(value.recipientID, value.requestID)) return 'conflict'
        if (!this.takeBudget('group-recipient', 20)) return 'limited'
        const inbox = [...this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix })]
        if (inbox.length >= maxLiveGroupInvitations) return 'limited'
        this.pruneGroupInvitationResults(now)
        const retained = [...this.storage.kv.list({ prefix: invitationResultPrefix, limit: maxStoredGroupInvitations - inbox.length })]
        if (inbox.length + retained.length >= maxStoredGroupInvitations) return 'limited'
        // Decide before inserting, in the same synchronous storage operation.
        // Parallel submissions must not each suppress the alert because the other one exists.
        const shouldNotify = !inbox.some(([, other]) => other.sender.userID === value.sender.userID && other.noticeID === value.noticeID)
        this.storage.kv.put(invitationPrefix + value.requestID, {
            ...value, retainUntil: now + groupInvitationSyncLifetime, recipientDeviceID: address?.auth.deviceID
        })
        return shouldNotify ? 'notify' : 'stored'
    }
    invitation(userID: string, requestID: string): NotificationGroupInvitation | null {
        if (!this.isCurrent(userID)) return null
        const value = this.storage.kv.get<NotificationGroupInvitation>(invitationPrefix + requestID)
        return value && value.expiresAt > Date.now() ? value : null
    }
    invitationStatus(userID: string, requestID: string): GroupInvitationStatus | null {
        const value = this.invitation(userID, requestID)
        return value ? this.invitationStatusFields(value) : this.invitationResult(userID, requestID)
    }
    private invitationStatusFields(value: NotificationGroupInvitation): GroupInvitationStatus {
        return { senderUserID: value.sender.userID, recipientDeviceID: value.recipientDeviceID,
            expiresAt: value.expiresAt, status: value.status }
    }
    private invitationResult(userID: string, requestID: string): RetainedGroupInvitationResult | null {
        if (!this.isCurrent(userID)) return null
        const now = Date.now()
        const result = this.storage.kv.get<RetainedGroupInvitationResult>(invitationResultPrefix + requestID)
        if (result && result.retainUntil > now) return result
        // An alarm may not have compacted an expired invitation yet.
        const invite = this.storage.kv.get<NotificationGroupInvitation>(invitationPrefix + requestID)
        if (!invite || invite.expiresAt > now || invite.status === 'queued' || !invite.retainUntil || invite.retainUntil <= now) return null
        return { ...this.invitationStatusFields(invite), status: invite.status, retainUntil: invite.retainUntil }
    }
    private acceptsAdditionalDevices(value: NotificationGroupInvitation) {
        return !value.sourceRequestID && value.status !== 'cancelled' && !value.additionalDevicesClosed
            && this.grantActive(value.recipientID, value.grantHash)
    }
    private invitationAcceptingAdditionalDevices(recipient: string, requestID: string) {
        const value = this.invitation(recipient, requestID)
        return value && value.recipientID === recipient && this.acceptsAdditionalDevices(value) ? value : null
    }
    invitationIDsForAdditionalDevice(auth: NotificationAuth, recipientKey: string): string[] | null {
        if (!this.authorized(auth)) return null
        const now = Date.now()
        const invitations = Array.from(this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix }), ([, value]) => value)
            .filter(value => value.recipientID === auth.userID && value.expiresAt > now)
        const noticeKey = (value: NotificationGroupInvitation) => `${value.sender.userID}:${value.noticeID}`
        const addressed = new Set<string>()
        const eligible: NotificationGroupInvitation[] = []
        for (const value of invitations) {
            // Even a cancelled copy already addressed to this key must not be offered again.
            if (value.recipientKey === recipientKey) {
                const queuedRedelivery = value.status === 'queued' && value.sourceRequestID !== undefined
                if (!queuedRedelivery || this.addressForRedelivery(value)?.auth.deviceID === auth.deviceID) {
                    addressed.add(noticeKey(value))
                }
            }
            if (!this.acceptsAdditionalDevices(value)) continue
            if (value.additionalDevices?.some(device => device.recipientKey === recipientKey && device.expiresAt > now
                && device.auth.deviceID === auth.deviceID && device.auth.tokenHash === auth.tokenHash)) {
                addressed.add(noticeKey(value))
            }
            eligible.push(value)
        }
        const ids: string[] = []
        for (const value of eligible) {
            const notice = noticeKey(value)
            if (addressed.has(notice)) continue
            addressed.add(notice)
            ids.push(value.requestID)
        }
        return ids
    }
    private activeInvitationDevices(value: NotificationGroupInvitation) {
        return (value.additionalDevices ?? []).filter(device => device.expiresAt > Date.now() && this.authorized(device.auth))
    }
    private addressForRedelivery(value: NotificationGroupInvitation) {
        if (!value.sourceRequestID || value.sourceRequestID === value.requestID) return null
        const source = this.invitationAcceptingAdditionalDevices(value.recipientID, value.sourceRequestID)
        if (!source || source.sender.accountID !== value.sender.accountID || source.sender.userID !== value.sender.userID
            || source.sender.deviceID !== value.sender.deviceID || source.noticeID !== value.noticeID
            || source.expiresAt !== value.expiresAt || source.grantHash !== value.grantHash) return null
        const devices = this.activeInvitationDevices(source).filter(device => device.recipientKey === value.recipientKey)
        return devices.length === 1 ? devices[0] : null
    }
    addInvitationDevice(auth: NotificationAuth, requestID: string, address: InvitationDeviceAddress) {
        if (!this.authorized(auth)) return false
        const value = this.invitationAcceptingAdditionalDevices(auth.userID, requestID)
        if (!value || address.expiresAt <= Date.now()) return false
        if (value.recipientKey === address.recipientKey) return true
        // Keep one short-lived destination per authenticated device on this exact invitation.
        const additionalDevices = this.activeInvitationDevices(value).filter(device => device.auth.deviceID !== auth.deviceID)
        additionalDevices.push({ ...address, expiresAt: Math.min(address.expiresAt, value.expiresAt), auth })
        this.storage.kv.put(invitationPrefix + requestID, { ...value, additionalDevices })
        return true
    }
    invitationDevices(sender: NotificationAuth, recipient: string, requestID: string) {
        const value = this.invitationAcceptingAdditionalDevices(recipient, requestID)
        if (!value || value.sender.accountID !== sender.accountID || value.sender.userID !== sender.userID
            || value.sender.deviceID !== sender.deviceID) return null
        return this.activeInvitationDevices(value).map(({ memberID, recipientKey }) => ({ memberID, recipientKey }))
    }
    pendingInvitations(userID: string, recipientKey: string): Pick<NotificationGroupInvitation, 'requestID' | 'sender'>[] {
        this.prune()
        return [...this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix })].map(([, v]) => v)
            .filter(v => v.recipientID === userID && v.recipientKey === recipientKey && v.status === 'queued' && this.grantActive(userID, v.grantHash))
            .map(({ requestID, sender }) => ({ requestID, sender }))
    }
    invitationForDelivery(auth: NotificationAuth, recipientKey: string, requestID: string, verifiedSender: NotificationAuth) {
        if (!this.authorized(auth)) return 'unauthorized'
        // Read the current envelope after the Worker awaited the sender's account.
        const value = this.invitation(auth.userID, requestID)
        if (!value?.envelope || value.status !== 'queued' || value.recipientID !== auth.userID
            || value.recipientKey !== recipientKey || !this.grantActive(auth.userID, value.grantHash)) return null
        if (value.sourceRequestID && (auth.deviceID !== value.recipientDeviceID
            || this.addressForRedelivery(value)?.auth.deviceID !== auth.deviceID)) return null
        const sender = value.sender
        if (sender.accountID !== verifiedSender.accountID || sender.userID !== verifiedSender.userID
            || sender.deviceID !== verifiedSender.deviceID || sender.tokenHash !== verifiedSender.tokenHash) return null
        return { requestID, senderUserID: sender.userID, recipientKey, expiresAt: value.expiresAt, envelope: value.envelope,
            sourceRequestID: value.sourceRequestID }
    }
    finishInvitation(userID: string, requestID: string, actorID: string, discard = false,
                     recipientAuth?: NotificationAuth, expectedExpiry?: number): 'received' | 'cancelled' | null {
        const value = this.invitation(userID, requestID)
        if (!value) {
            const result = this.invitationResult(userID, requestID)
            if (!result || (actorID !== userID && actorID !== result.senderUserID)) return null
            if (expectedExpiry !== undefined && expectedExpiry !== result.expiresAt) return null
            if (actorID === userID && result.recipientDeviceID !== undefined
                && (!recipientAuth || !this.authorized(recipientAuth) || recipientAuth.userID !== userID
                    || recipientAuth.deviceID !== result.recipientDeviceID)) return null
            return result.status
        }
        if (actorID !== userID && actorID !== value.sender.userID) return null
        if (expectedExpiry !== undefined && expectedExpiry !== value.expiresAt) return null
        const withdrawing = actorID === value.sender.userID
        if (!withdrawing && value.sourceRequestID && (!recipientAuth || !this.authorized(recipientAuth)
            || recipientAuth.userID !== userID || recipientAuth.deviceID !== value.recipientDeviceID)) return null
        const next = { ...value, envelope: null }
        if (next.status === 'queued') {
            const address = value.sourceRequestID ? this.addressForRedelivery(value) : null
            const canReceive = !value.sourceRequestID || (address !== null && address.auth.deviceID === next.recipientDeviceID)
            next.status = !withdrawing && !discard && canReceive ? 'received' : 'cancelled'
        }
        if (next.status === value.status && (!withdrawing || value.additionalDevicesClosed)) return next.status
        // An old receipt remains visible after the sender closes future deliveries.
        if (withdrawing) next.additionalDevicesClosed = true
        this.storage.transactionSync(() => {
            if (next.status === 'cancelled' || withdrawing) {
                delete next.additionalDevices
                for (const [key, child] of this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix })) {
                    if (child.sourceRequestID === requestID && child.status === 'queued') {
                        this.storage.kv.put(key, { ...child, envelope: null, status: 'cancelled' })
                    }
                }
            }
            this.storage.kv.put(invitationPrefix + requestID, next)
        })
        return next.status
    }
    invitationCandidates(userID: string, requestID: string): NotificationDevice[] {
        const value = this.invitation(userID, requestID)
        return value?.status === 'queued' && this.grantActive(userID, value.grantHash) ? this.devices().filter(v =>
            this.authorized({ accountID: '', userID, deviceID: v.deviceID, tokenHash: v.tokenHash }) && v.expiresAt > Date.now()).slice(0, 8) : []
    }
    prune() {
        const now = Date.now()
        for (const [key, value] of this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix })) {
            if (value.expiresAt > now) continue
            const { status, retainUntil } = value
            if (status === 'queued' || !retainUntil || retainUntil <= now) this.storage.kv.delete(key)
            else this.storage.transactionSync(() => {
                const result: RetainedGroupInvitationResult = { ...this.invitationStatusFields(value), status, retainUntil }
                this.storage.kv.put(invitationResultPrefix + value.requestID, result)
                this.storage.kv.delete(key)
            })
        }
        for (const [key, value] of this.storage.kv.list<NotificationCall>({ prefix: callPrefix })) if (value.forgetAt <= Date.now()) this.storage.kv.delete(key)
        for (const [key, value] of this.storage.kv.list<NotificationDevice>({ prefix: devicePrefix })) if (value.expiresAt <= Date.now()) this.storage.kv.delete(key)
    }
    pruneUnstoredGroupCancellations() {
        const now = Date.now()
        for (const [key, expiresAt] of this.storage.kv.list<number>({ prefix: groupCancellationPrefix })) if (expiresAt <= now) this.storage.kv.delete(key)
    }
    pruneGroupInvitationResults(now = Date.now()) {
        for (const [key, result] of this.storage.kv.list<RetainedGroupInvitationResult>({ prefix: invitationResultPrefix })) {
            if (result.retainUntil <= now) this.storage.kv.delete(key)
        }
    }
    deadlines(): number[] {
        return [...this.storage.kv.list<NotificationCall>({ prefix: callPrefix })].map(([, value]) => value.forgetAt)
            .concat([...this.storage.kv.list<NotificationGroupInvitation>({ prefix: invitationPrefix })].map(([, value]) => value.expiresAt))
            .concat([...this.storage.kv.list<RetainedGroupInvitationResult>({ prefix: invitationResultPrefix })].map(([, result]) => result.retainUntil))
            .concat([...this.storage.kv.list<number>({ prefix: groupCancellationPrefix })].map(([, expiresAt]) => expiresAt))
    }
}
