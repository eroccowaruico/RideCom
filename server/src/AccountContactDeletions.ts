import type { NotificationAuth } from './AccountNotifications'

type State = 'pending' | 'received' | 'retired'
interface Address { id: string; expiresAt: number }
export interface ContactDeletionRelayPacket extends Address {
    recipient: string; recipientKey: string; packet: string; packetHash: string
}
type ActiveEntry = Omit<ContactDeletionRelayPacket, 'packet'> & {
    deviceID: string
    state: 'pending' | 'received'
    packet: string
}
type Entry = ActiveEntry | Address & { deviceID: string; state: 'retired' }
const prefix = 'contact-deletion:'
const capacity = 64

/** Opaque packets live in the owner's account. Each synchronous transition belongs to one slot. */
export class AccountContactDeletions {
    constructor(private readonly storage: DurableObjectStorage) {}

    publish(auth: NotificationAuth, slotHash: string, value: ContactDeletionRelayPacket) {
        if (value.expiresAt <= Date.now()) return 'expired'
        const previous = this.entry(slotHash)
        if (previous) {
            if (!this.sameDeletion(previous, auth, value)) return 'conflict'
            if (previous.state !== 'retired' && (previous.packetHash !== value.packetHash
                || previous.recipient !== value.recipient || previous.recipientKey !== value.recipientKey)) return 'conflict'
            return previous.state
        }
        return this.create(slotHash, { ...value, deviceID: auth.deviceID, state: 'pending' })
    }

    retire(auth: NotificationAuth, slotHash: string, value: Address) {
        if (value.expiresAt <= Date.now()) return 'expired'
        const previous = this.entry(slotHash)
        if (previous && !this.sameDeletion(previous, auth, value)) return 'conflict'
        const entry = { ...value, deviceID: auth.deviceID, state: 'retired' } as const
        if (!previous) return this.create(slotHash, entry)
        this.storage.kv.put(prefix + slotHash, entry)
        return entry.state
    }

    readReceipt(auth: NotificationAuth, slotHash: string) {
        const entry = this.entry(slotHash)
        return entry?.state === 'received' && entry.deviceID === auth.deviceID
            ? { id: entry.id, expiresAt: entry.expiresAt, packet: entry.packet } : null
    }

    readNotice(owner: string, slotHash: string, recipient: string, key: string) {
        const entry = this.forRecipient(owner, slotHash, recipient, key)
        return entry?.state === 'pending' ? { id: entry.id, expiresAt: entry.expiresAt, packet: entry.packet } : null
    }

    acknowledge(owner: string, slotHash: string, recipient: string, key: string, id: string, packet: string) {
        const entry = this.forRecipient(owner, slotHash, recipient, key)
        if (!entry || entry.id !== id) return 'missing'
        if (entry.state === 'received') return entry.packet === packet ? 'received' : 'conflict'
        this.storage.kv.put(prefix + slotHash, { ...entry, state: 'received', packet })
        return 'received'
    }

    prune(now = Date.now()) {
        for (const [key, entry] of this.entries()) if (entry.expiresAt <= now) this.storage.kv.delete(key)
    }
    deadlines() { return this.entries().map(([, entry]) => entry.expiresAt) }
    clear() { for (const [key] of this.entries()) this.storage.kv.delete(key) }

    private entry(slotHash: string) {
        const entry = this.storage.kv.get<Entry>(prefix + slotHash)
        return entry && entry.expiresAt > Date.now() ? entry : null
    }
    private entries() { return [...this.storage.kv.list<Entry>({ prefix })] }
    private create(slotHash: string, entry: Entry): State | 'limited' {
        this.prune()
        if (this.entries().length >= capacity) return 'limited'
        this.storage.kv.put(prefix + slotHash, entry)
        return entry.state
    }
    private sameDeletion(entry: Entry, auth: NotificationAuth, value: Address) {
        return entry.deviceID === auth.deviceID && entry.id === value.id && entry.expiresAt === value.expiresAt
    }
    private forRecipient(owner: string, slotHash: string, recipient: string, key: string) {
        if (this.storage.kv.get('userID') !== owner) return null
        const entry = this.entry(slotHash)
        return entry && entry.state !== 'retired' && entry.recipient === recipient && entry.recipientKey === key ? entry : null
    }
}
