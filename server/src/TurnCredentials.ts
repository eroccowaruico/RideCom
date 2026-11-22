import type { Env } from './types'
export interface IceServer { urls: string[]; username?: string; credential?: string }
interface Issued { username: string; keyID: string; expiresAt: number }
export interface IceLease {
    peer: string; owner: string; leaseID: string; expiresAt: number
    servers: IceServer[]; issued: Issued[]
}
export const stun: IceServer[] = [{ urls: ['stun:stun.cloudflare.com:3478'] }]

function isIceServer(value: unknown): value is IceServer {
    if (!value || typeof value !== 'object' || !('urls' in value)) return false
    const urls: unknown = value.urls
    if (!Array.isArray(urls) || !urls.length || urls.length > 16
        || !urls.every((url: unknown): url is string => typeof url === 'string' && /^(stun|turn|turns):[^\s]+$/.test(url))) return false
    if ('username' in value && typeof value.username !== 'string') return false
    if ('credential' in value && typeof value.credential !== 'string') return false
    return !urls.some(url => url.startsWith('turn'))
        || ('username' in value && !!value.username && 'credential' in value && !!value.credential)
}

/** Owns short-lived credentials; SFU/group lifecycle stays in SignalingRoom. */
export class TurnCredentials {
    constructor(private storage: DurableObjectStorage, private env: Env) {}
    get enabled() { return this.env.TURN_ENABLED === 'true' }
    private get keyID() { return this.env.CLOUDFLARE_TURN_API_TOKEN ? this.env.CLOUDFLARE_TURN_KEY_ID : undefined }
    get configured() { return !!this.keyID }
    async get(peer: string) { return this.storage.get<IceLease>(`ice:${peer}`) }
    async all() { return [...(await this.storage.list<IceLease>({ prefix: 'ice:' })).values()] }
    async issue(peer: string, owner: string, leaseID: string, expiresAt: number): Promise<IceServer[]> {
        if (!this.enabled) return stun
        const keyID = this.keyID
        if (!keyID) throw new Error('turn-configuration')
        const old = await this.get(peer)
        if (old && (old.owner !== owner || old.leaseID !== leaseID)) throw new Error('ice-conflict')
        if (old && old.expiresAt >= expiresAt && old.servers.length) return old.servers
        const ttl = Math.max(1, Math.min(7200, Math.ceil((expiresAt - Date.now()) / 1000)))
        // Persist the bounded lifetime before an external request, including its failure path.
        const lease: IceLease = old ?? { peer, owner, leaseID, expiresAt, servers: [], issued: [] }
        await this.storage.put(`ice:${peer}`, lease)
        const response = await this.provider(keyID, 'credentials/generate-ice-servers', { ttl })
        if (!response.ok) throw new Error('turn-upstream')
        const body: unknown = await response.json()
        if (!body || typeof body !== 'object' || !('iceServers' in body)) throw new Error('turn-response')
        const servers = body.iceServers
        if (!Array.isArray(servers) || !servers.length || servers.length > 8 || !servers.every(isIceServer)) {
            throw new Error('turn-response')
        }
        const usernames = [...new Set(servers.flatMap(server =>
            server.username && server.urls.some(url => url.startsWith('turn')) ? [server.username] : []))]
        if (!usernames.length) throw new Error('turn-response')
        // Keep prior credentials until their expiry, so a response/configuration race cannot cut live media.
        lease.issued = lease.issued.filter(c => c.expiresAt > Date.now())
        for (const username of usernames) lease.issued.push({ username, keyID, expiresAt: Date.now() + ttl * 1000 })
        lease.expiresAt = expiresAt; lease.servers = servers
        await this.storage.put(`ice:${peer}`, lease)
        return servers
    }
    async remove(lease: IceLease): Promise<void> {
        // Mark cleanup pending before I/O so a failed revoke is retried by the alarm.
        lease.expiresAt = 0
        await this.storage.put(`ice:${lease.peer}`, lease)
        // Attempt every live credential; retain the record if any revocation needs retry.
        await Promise.all(lease.issued.filter(c => c.expiresAt > Date.now()).map(async c => {
            const response = await this.provider(c.keyID, `credentials/${encodeURIComponent(c.username)}/revoke`)
            if (!response.ok && response.status !== 404 && response.status !== 410) throw new Error('turn-revoke')
        }))
        await this.storage.delete(`ice:${lease.peer}`)
    }
    private provider(keyID: string, path: string, body?: unknown) {
        const token = this.env.CLOUDFLARE_TURN_API_TOKEN
        if (!token) throw new Error('turn-configuration')
        return fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${encodeURIComponent(keyID)}/${path}`, {
            method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
            ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(8000)
        })
    }
}
