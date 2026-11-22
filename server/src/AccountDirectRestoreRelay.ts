export interface DirectRestoreRelayPacket {
    id: string
    expiresAt: number
    sender: { userID: string; deviceID: string; sessionBinding: string }
    recipient: { deviceID: string; sessionBinding: string }
    packet: string
    packetHash: string
}

type Entry = Omit<DirectRestoreRelayPacket, 'packet'> & { packet: string | null }
export type DirectRestoreRelayCandidate = Pick<Entry, 'id' | 'expiresAt' | 'sender' | 'packetHash'>
const prefix = 'direct-restore:'
const capacity = 8

/** Short-lived opaque packets in the recipient's account. */
export class AccountDirectRestoreRelay {
    constructor(private readonly storage: DurableObjectStorage) {}

    put(value: DirectRestoreRelayPacket) {
        const now = Date.now()
        if (value.expiresAt <= now) return 'expired'
        this.prune(now)
        const key = this.key(value.recipient.deviceID, value.id)
        const previous = this.storage.kv.get<Entry>(key)
        if (previous) {
            if (previous.recipient.sessionBinding !== value.recipient.sessionBinding || !this.samePacket(previous, value)) {
                return 'conflict'
            }
            return previous.packet === null ? 'retired' : 'queued'
        }
        if (this.entries().length >= capacity) return 'limited'
        this.storage.kv.put<Entry>(key, value)
        return 'queued'
    }

    pending(deviceID: string, sessionBinding: string) {
        const now = Date.now()
        return Array.from(this.storage.kv.list<Entry>({ prefix: `${prefix}${deviceID}:` }), ([, entry]) => entry)
            .filter(entry => entry.expiresAt > now && entry.recipient.sessionBinding === sessionBinding
                && entry.packet !== null)
            .map(({ id, expiresAt, sender, packetHash }) => ({ id, expiresAt, sender, packetHash }))
    }

    read(deviceID: string, sessionBinding: string, expected: DirectRestoreRelayCandidate) {
        const entry = this.current(deviceID, sessionBinding, expected.id)
        if (!entry || entry.packet === null || !this.samePacket(entry, expected)) return null
        return { id: entry.id, senderUserID: entry.sender.userID, expiresAt: entry.expiresAt, packet: entry.packet }
    }

    retire(deviceID: string, sessionBinding: string, id: string) {
        const entry = this.current(deviceID, sessionBinding, id)
        if (!entry) return false
        if (entry.packet !== null) this.storage.kv.put<Entry>(this.key(deviceID, id), { ...entry, packet: null })
        return true
    }

    private current(deviceID: string, sessionBinding: string, id: string) {
        const entry = this.storage.kv.get<Entry>(this.key(deviceID, id))
        return entry && entry.expiresAt > Date.now() && entry.recipient.sessionBinding === sessionBinding ? entry : null
    }

    private samePacket(entry: Entry, expected: DirectRestoreRelayCandidate) {
        return entry.id === expected.id && entry.expiresAt === expected.expiresAt && entry.packetHash === expected.packetHash
            && entry.sender.userID === expected.sender.userID && entry.sender.deviceID === expected.sender.deviceID
            && entry.sender.sessionBinding === expected.sender.sessionBinding
    }

    private key(deviceID: string, id: string) { return `${prefix}${deviceID}:${id}` }
    private entries() { return [...this.storage.kv.list<Entry>({ prefix })] }
    deadlines() { return this.entries().map(([, entry]) => entry.expiresAt) }
    clear() { for (const [key] of this.entries()) this.storage.kv.delete(key) }
    prune(now = Date.now()) {
        for (const [key, entry] of this.entries()) if (entry.expiresAt <= now) this.storage.kv.delete(key)
    }
}
