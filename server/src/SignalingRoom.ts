import { TurnCredentials, stun } from './TurnCredentials'
import { type Env, type Member, dataDescription, isRecord, json, limit, readJSON, sfu, sfuConfigured } from './types'
interface RequestedChannel {
    location: 'local' | 'remote'
    dataChannelName: string
    sessionId?: string
    ordered: boolean
    maxRetransmits?: number
}

function responseChannels(response: Record<string, unknown>): Record<string, unknown>[] {
    const channels = response.dataChannels
    if (channels == null) return []
    if (!Array.isArray(channels) || !channels.every(isRecord)) throw new Error('upstream')
    return channels
}

function hasChannelID(channel: Record<string, unknown>): channel is Record<string, unknown> & { id: number } {
    return typeof channel.id === 'number' && Number.isInteger(channel.id)
}

async function reservationExpiry(response: Response): Promise<number> {
    const data: unknown = await response.json()
    if (!isRecord(data) || typeof data.expiresAt !== 'number' || !Number.isFinite(data.expiresAt)) {
        throw new Error('Invalid reservation response')
    }
    return data.expiresAt
}

export class SignalingRoom implements DurableObject {
    private turn: TurnCredentials
    constructor(private state: DurableObjectState, private env: Env) { this.turn = new TurnCredentials(state.storage, env) }
    private usage(path: string, body: unknown) {
        return this.env.USAGE_GUARD.get(this.env.USAGE_GUARD.idFromName('global')).fetch(new Request(`https://internal/${path}`, { method: 'POST', body: JSON.stringify(body) }))
    }
    private async members(): Promise<Member[]> { return [...(await this.state.storage.list<Member>({ prefix: 'member:' })).values()] }
    private lease(m: Member) { return { sessionId: m.sessionId, expiresAt: m.expiresAt, renewAfterSeconds: limit(this.env.LEASE_SECONDS, 600, 3600) / 2 } }
    private usesConfiguredSFU(member: Member): boolean {
        return sfuConfigured(this.env) && member.sfuAppID === this.env.CLOUDFLARE_SFU_APP_ID
    }
    async fetch(request: Request): Promise<Response> {
        return this.state.blockConcurrencyWhile(async () => {
            try {
                if (new URL(request.url).pathname === '/retire-account') return await this.retireAccount(await readJSON(request))
                const accountID = request.headers.get('X-User'), publicUserID = request.headers.get('X-Owner')?.split(':')[0]
                if (accountID && publicUserID) {
                    const account = this.env.USER_ACCOUNT.get(this.env.USER_ACCOUNT.idFromString(accountID))
                    if (!await account.attachRoom(publicUserID, this.state.id.toString())) return json({ error: 'Account access ended' }, 403)
                    await this.state.storage.put(`account:${publicUserID}`, accountID)
                }
                try { return await this.handle(request) }
                finally { if (accountID && publicUserID) await this.detachIfEmpty(publicUserID, accountID) }
            }
            catch (e) { const invalid = e instanceof Error && e.message === 'body'; return json({ error: invalid ? 'Invalid body' : 'SFU operation failed' }, invalid ? 400 : 502) }
        })
    }
    private async detachIfEmpty(publicUserID: string, accountID: string) {
        const prefix = `${publicUserID}:`
        if ((await this.members()).some(m => m.owner.startsWith(prefix)) || (await this.turn.all()).some(ice => ice.owner.startsWith(prefix))) return
        await this.env.USER_ACCOUNT.get(this.env.USER_ACCOUNT.idFromString(accountID)).detachRoom(publicUserID, this.state.id.toString())
        await this.state.storage.delete(`account:${publicUserID}`)
    }
    private async retireAccount(body: Record<string, unknown>): Promise<Response> {
        if (typeof body.publicUserID !== 'string' || typeof body.accountID !== 'string'
            || !/^[a-f0-9]{64}$/.test(body.publicUserID) || !/^[a-f0-9]{64}$/.test(body.accountID)) return json({ error: 'Invalid account' }, 400)
        const prefix = `${body.publicUserID}:`
        const members = (await this.members()).filter(m => m.owner.startsWith(prefix))
        const owned = new Set(members.map(m => m.id))
        const orphans = (await this.turn.all()).filter(ice => ice.owner.startsWith(prefix) && !owned.has(ice.peer))
        // End signaling and admission before contacting external media providers.
        for (const member of members) {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            for (const ws of this.state.getWebSockets(member.sessionId)) { try { ws.close(1000, 'Account deleted') } catch { /* closed */ } }
        }
        for (const ice of orphans) await this.turn.prepareRevocation(ice)
        await this.scheduleExpiry()
        await this.broadcastPeers()
        await Promise.all([...members.map(async member => { try { await this.close(member) } catch { /* Retain for retry. */ } }),
            ...orphans.map(async ice => { try { await this.turn.remove(ice) } catch { /* Retain for retry. */ } })])
        await this.scheduleExpiry()
        if ((await this.members()).some(m => m.owner.startsWith(prefix)) || (await this.turn.all()).some(ice => ice.owner.startsWith(prefix))) return json({ pending: true }, 503)
        // Release by both private account and public generation. A delayed old
        // cleanup must not release a newly registered account's reservation.
        const released = await this.usage('release-account-room', { ...body, roomID: this.state.id.toString() })
        if (!released.ok) return released
        await this.detachIfEmpty(body.publicUserID, body.accountID)
        await this.scheduleExpiry()
        return json({})
    }
    private async handle(request: Request): Promise<Response> {
        const url = new URL(request.url), owner = request.headers.get('X-Owner')
        if (!owner) return json({ error: 'Unauthorized' }, 401)
        const userID = request.headers.get('X-User') ?? undefined
        const members = await this.members()
        const iceMatch = url.pathname.match(/\/ice\/([a-zA-Z0-9_-]{1,80})$/)
        if (iceMatch) {
            const peer = iceMatch[1], b = await readJSON(request)
            if (typeof b.leaseID !== 'string' || !/^[a-zA-Z0-9_-]{1,80}$/.test(b.leaseID)) return json({ error: 'Invalid ICE lease' }, 400)
            const current = await this.turn.get(peer)
            if (current && current.owner !== owner) return json({ error: 'Forbidden' }, 403)
            if (current && current.leaseID !== b.leaseID) return json({ error: 'ICE lease changed' }, 409)
            if (request.method === 'DELETE') {
                if (members.some(m => m.id === peer)) return json({ error: 'Session owns ICE lease' }, 409)
                if (current) {
                    try { await this.turn.remove(current); await this.usage('release', { id: `${this.state.id}:${peer}` }) }
                    finally { await this.scheduleExpiry() }
                }
                await this.scheduleExpiry(); return json({})
            }
            if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
            if (!this.turn.enabled) return json({ iceServers: stun })
            if (!this.turn.configured) return json({ error: 'TURN is not configured' }, 503)
            if (members.some(m => m.id === peer)) return json({ error: 'Participant already connected' }, 409)
            const pending = await this.turn.all()
            if (!current && new Set([...members.map(m => m.id), ...pending.map(m => m.peer)]).size >= limit(this.env.MAX_ROOM_PARTICIPANTS, 8, 8)) return json({ error: 'Room is full' }, 429)
            const reservation = await this.usage('reserve', { id: `${this.state.id}:${peer}`, owner, userID })
            if (!reservation.ok) return reservation
            const expiresAt = await reservationExpiry(reservation)
            try { return json({ iceServers: await this.turn.issue(peer, owner, b.leaseID, expiresAt) }) }
            finally { await this.scheduleExpiry() }
        }
        if (url.pathname.endsWith('/join') && request.method === 'POST') {
            if (members.some(m => !this.usesConfiguredSFU(m))) return json({ error: 'SFU configuration changed' }, 503)
            const b = await readJSON(request)
            if (typeof b.participantId !== 'string' || !/^[a-zA-Z0-9_-]{1,63}$/.test(b.participantId)
                || !dataDescription(b.offer, 'offer') || b.offer.sdp.split(/\r?\n/).filter((l: string) => l.startsWith('m=')).length !== 1) return json({ error: 'One SCTP application section is required' }, 400)
            if (members.some(m => m.id === b.participantId)) return json({ error: 'Participant already connected' }, 409)
            if (members.length >= limit(this.env.MAX_ROOM_PARTICIPANTS, 8, 8)) return json({ error: 'Room is full' }, 429)
            if (this.turn.enabled) {
                const ice = await this.turn.get(b.participantId)
                if (!ice || ice.owner !== owner || ice.leaseID !== b.iceLeaseID || ice.expiresAt <= Date.now() || !ice.servers.length) return json({ error: 'Valid ICE lease required' }, 403)
            }
            const leaseID = `${this.state.id}:${b.participantId}`
            const reservation = await this.usage('reserve', { id: leaseID, owner, userID })
            if (!reservation.ok) return reservation
            const expiresAt = await reservationExpiry(reservation)
            let member: Member | undefined
            try {
                const created = await sfu(this.env, '/sessions/new')
                if (typeof created.sessionId !== 'string') throw new Error('upstream')
                member = { id: b.participantId, owner, sessionId: created.sessionId,
                    sfuAppID: this.env.CLOUDFLARE_SFU_APP_ID, expiresAt, channels: [], subscriptions: [] }
                // Persist before publishing; a lost upstream response must still be cleaned up.
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.scheduleExpiry()
                const result = await sfu(this.env, `/sessions/${member.sessionId}/datachannels/establish`, {
                    sessionDescription: b.offer, dataChannel: { location: 'remote', dataChannelName: 'server-events' }
                })
                if (!isRecord(result.sessionDescription) || result.sessionDescription.type !== 'answer'
                    || typeof result.sessionDescription.sdp !== 'string' || !isRecord(result.dataChannel)
                    || !hasChannelID(result.dataChannel)) throw new Error('upstream')
                member.channels = [result.dataChannel.id]
                await this.state.storage.put(`member:${member.sessionId}`, member)
                return json({ ...this.lease(member), sessionDescription: result.sessionDescription,
                    channels: [{ id: result.dataChannel.id, isPublisher: false, delivery: 'reliable' }] })
            } catch (e) {
                if (member) { member.expiresAt = 0; await this.state.storage.put(`member:${member.sessionId}`, member); await this.state.storage.setAlarm(Date.now() + 1000) }
                // A created session keeps its slot until cleanup confirms its media is gone.
                if (!member) await this.usage('release', { id: leaseID })
                throw e
            }
        }
        const match = url.pathname.match(/\/sessions\/([^/]+)(?:\/(\w+))?$/)
        const member = members.find(m => m.sessionId === match?.[1])
        if (!member) return json({ error: 'Session not found' }, 404)
        if (member.owner !== owner) return json({ error: 'Forbidden' }, 403)
        if (member.expiresAt <= Date.now()) return json({ error: 'Lease expired' }, 410)
        const action = match?.[2]
        if (!action && request.method === 'DELETE') {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            await this.state.storage.setAlarm(Date.now() + 1000)
            await this.close(member); await this.broadcastPeers(); await this.scheduleExpiry(); return json({})
        }
        if (!this.usesConfiguredSFU(member)) return json({ error: 'SFU configuration changed' }, 503)
        if (action === 'signal' && request.headers.get('Upgrade')?.toLowerCase() === 'websocket') {
            if (this.state.getWebSockets(member.sessionId).length) return json({ error: 'Signaling already connected' }, 409)
            const pair = new WebSocketPair(); this.state.acceptWebSocket(pair[1], [member.sessionId])
            pair[1].serializeAttachment({ count: 0, minute: 0 }); await this.broadcastPeers()
            return new Response(null, { status: 101, webSocket: pair[0] })
        }
        if (action === 'renew' && request.method === 'POST') {
            const r = await this.usage('reserve', { id: `${this.state.id}:${member.id}`, owner, userID })
            if (!r.ok) return r
            member.expiresAt = await reservationExpiry(r)
            await this.state.storage.put(`member:${member.sessionId}`, member); await this.scheduleExpiry()
            const ice = await this.turn.get(member.id)
            const iceServers = ice ? await this.turn.issue(member.id, owner, ice.leaseID, member.expiresAt) : undefined
            return json({ ...this.lease(member), ...(iceServers ? { iceServers } : {}) })
        }
        if (action === 'publish' && request.method === 'POST') {
            if (!member.publishers) {
                const channels = await this.allocate(member, {
                    dataChannels: [{ location: 'local', dataChannelName: 'group-audio-v1', ordered: false, maxRetransmits: 0 }, { location: 'local', dataChannelName: 'group-control-v1', ordered: true }]
                })
                member.publishers = ['group-audio-v1', 'group-control-v1'].map(name => {
                    const channel = channels.find(c => c.dataChannelName === name)
                    if (!channel) throw new Error('upstream')
                    return { id: channel.id, delivery: name === 'group-audio-v1' ? 'unreliable' : 'reliable' }
                })
                await this.state.storage.put(`member:${member.sessionId}`, member)
                await this.broadcastPeers()
            }
            return json({ channels: member.publishers.map(c => ({ ...c, isPublisher: true })) })
        }
        if (action === 'pull' && request.method === 'POST') {
            const { peerIds } = await readJSON(request)
            if (!Array.isArray(peerIds) || peerIds.length > 7 || peerIds.some((id: unknown) => typeof id !== 'string')) return json({ error: 'Invalid peers' }, 400)
            const peers = members.filter(m => m.id !== member.id && peerIds.includes(m.id) && m.publishers !== undefined
                && m.expiresAt > Date.now() && this.usesConfiguredSFU(m))
            if (new Set(peerIds).size !== peers.length) {
                return json({ error: 'Peer not in room', code: 'peer_snapshot_changed' }, 403)
            }
            const live = new Set(members.filter(m => m.expiresAt > Date.now() && this.usesConfiguredSFU(m)).map(m => m.sessionId))
            const stale = member.subscriptions.filter(s => !live.has(s.sessionId))
            if (stale.length) {
                await this.closeChannels(member.sessionId, stale.map(s => s.id))
                member.channels = member.channels.filter(id => !stale.some(s => s.id === id))
                member.subscriptions = member.subscriptions.filter(s => live.has(s.sessionId))
                await this.state.storage.put(`member:${member.sessionId}`, member)
            }
            const fresh = peers.filter(p => !member.subscriptions.some(s => s.sessionId === p.sessionId))
            if (fresh.length) {
                const channels = await this.allocate(member, {
                    dataChannels: fresh.flatMap(p => [{ location: 'remote', sessionId: p.sessionId, dataChannelName: 'group-audio-v1', ordered: false, maxRetransmits: 0 }, { location: 'remote', sessionId: p.sessionId, dataChannelName: 'group-control-v1', ordered: true }])
                })
                for (const peer of fresh) {
                    for (const name of ['group-audio-v1', 'group-control-v1']) {
                        const channel = channels.find(c => c.sessionId === peer.sessionId && c.dataChannelName === name)
                        if (!channel) throw new Error('upstream')
                        member.subscriptions.push({ sessionId: peer.sessionId, id: channel.id, peerId: peer.id, delivery: name === 'group-audio-v1' ? 'unreliable' : 'reliable' })
                    }
                }
                await this.state.storage.put(`member:${member.sessionId}`, member)
            }
            return json({ channels: member.subscriptions.map(s => ({ id: s.id, peerID: s.peerId, isPublisher: false, delivery: s.delivery })) })
        }
        return json({ error: 'Not found' }, 404)
    }
    async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
        const [id] = this.state.getTags(ws), member = await this.state.storage.get<Member>(`member:${id}`)
        if (!member || member.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true' || !this.usesConfiguredSFU(member)) { ws.close(1008, 'Session unavailable'); return }
        const previous: unknown = ws.deserializeAttachment()
        if (!isRecord(previous) || typeof previous.minute !== 'number' || typeof previous.count !== 'number') {
            ws.close(1008, 'Invalid session state'); return
        }
        const minute = Math.floor(Date.now() / 60000)
        const count = (previous.minute === minute ? previous.count : 0) + 1
        ws.serializeAttachment({ minute, count })
        if (typeof message !== 'string' || new TextEncoder().encode(message).length > 32768 || count > 600) { ws.close(1008, 'Message limit'); return }
        let d: unknown
        try { d = JSON.parse(message) } catch { ws.close(1008, 'Invalid message'); return }
        if (!isRecord(d) || d.type !== 'appData' || typeof d.namespace !== 'string' || d.namespace.length > 128 || typeof d.payload !== 'string') { ws.close(1008, 'Invalid message'); return }
        const result = JSON.stringify({ type: 'appData', from: member.id, namespace: d.namespace, payload: d.payload })
        for (const socket of this.state.getWebSockets()) if (socket !== ws) { try { socket.send(result) } catch { /* closed */ } }
    }
    webSocketClose(ws: WebSocket): void { try { ws.close(1000, 'Closed') } catch { /* closed */ } }
    webSocketError(ws: WebSocket): void { this.webSocketClose(ws) }
    private async broadcastPeers() {
        const peers = (await this.members())
            .filter(m => m.publishers !== undefined && m.expiresAt > Date.now() && this.usesConfiguredSFU(m))
            .map(m => ({ id: m.id, sessionId: m.sessionId }))
        for (const ws of this.state.getWebSockets()) { try { ws.send(JSON.stringify({ type: 'peers', peers })) } catch { /* closed */ } }
    }
    private async close(member: Member) {
        const ice = await this.turn.get(member.id)
        if (ice) await this.turn.prepareRevocation(ice)
        if (!this.usesConfiguredSFU(member)) throw new Error('sfu-configuration')
        try {
            const status = await sfu(this.env, `/sessions/${member.sessionId}`, undefined, 'GET')
            const known = responseChannels(status).filter(hasChannelID).filter(c => c.status !== 'inactive').map(c => c.id)
            await this.closeChannels(member.sessionId, [...new Set([...member.channels, ...known])])
            // A timed-out allocation can complete after a status read. Keep its
            // cleanup record until the provider confirms the session is gone.
            if (member.allocationPending) throw new Error('pending-allocation')
        } catch (e) { if (!(e instanceof Error && e.message === 'session-gone')) throw e }
        if (ice) await this.turn.remove(ice)
        await this.state.storage.delete(`member:${member.sessionId}`)
        await this.usage('release', { id: `${this.state.id}:${member.id}` })
        for (const ws of this.state.getWebSockets(member.sessionId)) { try { ws.close(1000, 'Session ended') } catch { /* closed */ } }
    }
    private async allocate(member: Member, body: { dataChannels: RequestedChannel[] }) {
        member.allocationPending = true
        await this.state.storage.put(`member:${member.sessionId}`, member)
        try {
            const result = await sfu(this.env, `/sessions/${member.sessionId}/datachannels/new`, body)
            const received = responseChannels(result)
            const allocated = received.filter(hasChannelID).filter(channel => !channel.errorCode)
            member.channels = [...new Set([...member.channels, ...allocated.map(channel => channel.id)])]
            member.allocationPending = false
            await this.state.storage.put(`member:${member.sessionId}`, member)
            if (received.length !== body.dataChannels.length || allocated.length !== received.length) throw new Error('upstream')
            return allocated
        } catch (error) {
            member.expiresAt = 0
            await this.state.storage.put(`member:${member.sessionId}`, member)
            await this.state.storage.setAlarm(Date.now() + 1000)
            throw error
        }
    }
    private async closeChannels(sessionID: string, ids: number[]) {
        if (!ids.length) return
        const result = await sfu(this.env, `/sessions/${sessionID}/datachannels/close`, { dataChannels: ids.map(id => ({ id })) }, 'PUT')
        // A partial/missing response is not evidence of cleanup. Retain the lease for retry.
        const channels = responseChannels(result)
        for (const id of ids) if (!channels.some(c => c.id === id && (!c.errorCode || c.errorCode === 'close_track_error'))) throw new Error('upstream')
    }
    private async scheduleExpiry() {
        const members = await this.members()
        const ice = await this.turn.all()
        const deadlines = [...members.map(m => m.expiresAt), ...ice.map(m => m.expiresAt)]
        if (deadlines.length) await this.state.storage.setAlarm(Math.max(Date.now() + 1000, Math.min(...deadlines)))
        else if ((await this.state.storage.list({ prefix: 'account:' })).size) await this.state.storage.setAlarm(Date.now() + 30000)
        else await this.state.storage.deleteAlarm()
    }
    async alarm(): Promise<void> {
        await this.state.blockConcurrencyWhile(async () => {
        const members = await this.members()
        const expired = members.filter(m => m.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true')
        const active = new Set(members.map(m => m.id))
        const orphans = (await this.turn.all()).filter(ice => !active.has(ice.peer)
            && (ice.expiresAt <= Date.now() || this.env.SERVICE_ENABLED !== 'true'))
        // Member cleanup can take status + channel close + TURN revoke (3 x 8s).
        // Start orphan revocations concurrently so they do not add another 8s.
        // The snapshot excludes member-owned keys; no credential is revoked twice.
        await Promise.all([...expired.map(async m => {
            try { await this.close(m) } catch { /* Keep cleanup record and retry. */ }
        }), ...orphans.map(async ice => {
            try { await this.turn.remove(ice); await this.usage('release', { id: `${this.state.id}:${ice.peer}` }) } catch { /* Retain for retry/TTL expiry. */ }
        })])
        await this.broadcastPeers()
        for (const [key, accountID] of await this.state.storage.list<string>({ prefix: 'account:' })) {
            try { await this.detachIfEmpty(key.slice('account:'.length), accountID) } catch { /* Retry with the room alarm. */ }
        }
        const remaining = await this.members()
        if (remaining.some(m => m.expiresAt <= Date.now()) || (await this.turn.all()).some(m => m.expiresAt <= Date.now())) await this.state.storage.setAlarm(Date.now() + 30000)
        else await this.scheduleExpiry()
        })
    }
}
