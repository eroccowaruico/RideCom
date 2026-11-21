export interface OrdinaryGroupReplyPacket { id: string; packet: string }

interface Mailbox { deviceID: string; expiresAt: number }
interface Reply { recipient: string; packet: string; acknowledged: boolean }
export type OrdinaryGroupReplyStatus = 'ok' | 'missing' | 'conflict' | 'limited' | 'expired' | 'unauthorized'

const mailboxPrefix = 'ordinary-group-reply-mailbox:'
const replyPrefix = 'ordinary-group-reply-packet:'
const maximumMailboxes = 32
const maximumRecipients = 8

/** The owner account holds bounded, opaque packets. Each mutation runs without yielding. */
export class AccountOrdinaryGroupReplies {
    constructor(private readonly storage: DurableObjectStorage) {}

    open(deviceID: string, slot: string, expiresAt: number): OrdinaryGroupReplyStatus {
        if (expiresAt <= Date.now()) return 'expired'
        const existing = this.mailbox(slot)
        if (existing) return existing.deviceID === deviceID && existing.expiresAt === expiresAt ? 'ok' : 'conflict'
        this.prune()
        if (this.mailboxes().length >= maximumMailboxes) return 'limited'
        this.storage.kv.put(mailboxPrefix + slot, { deviceID, expiresAt })
        return 'ok'
    }

    accept(slot: string, recipient: string, value: OrdinaryGroupReplyPacket, expectedExpiry?: number): OrdinaryGroupReplyStatus {
        const mailbox = this.mailbox(slot)
        if (!mailbox) return 'missing'
        if (expectedExpiry !== undefined && mailbox.expiresAt !== expectedExpiry) return 'conflict'
        const key = this.prefix(slot) + value.id
        const previous = this.storage.kv.get<Reply>(key)
        if (previous) return previous.recipient === recipient ? 'ok' : 'conflict'
        const entries = this.replies(slot)
        if (entries.some(([, reply]) => reply.recipient === recipient)) return 'conflict'
        if (entries.length >= maximumRecipients) return 'limited'
        this.storage.kv.put(key, { recipient, packet: value.packet, acknowledged: false })
        return 'ok'
    }

    inbox(deviceID: string, slot: string): OrdinaryGroupReplyPacket[] | null {
        if (this.mailbox(slot)?.deviceID !== deviceID) return null
        const prefix = this.prefix(slot)
        return this.replies(slot).flatMap(([key, reply]) => reply.acknowledged ? [] : [{ id: key.slice(prefix.length), packet: reply.packet }])
    }

    acknowledge(deviceID: string, slot: string, value: OrdinaryGroupReplyPacket): OrdinaryGroupReplyStatus {
        if (this.mailbox(slot)?.deviceID !== deviceID) return 'missing'
        const key = this.prefix(slot) + value.id
        const reply = this.storage.kv.get<Reply>(key)
        if (!reply) return 'missing'
        if (!reply.acknowledged) this.storage.kv.put(key, { ...reply, packet: value.packet, acknowledged: true })
        return 'ok'
    }

    receipt(slot: string, recipient: string, id: string): OrdinaryGroupReplyPacket | null {
        if (!this.mailbox(slot)) return null
        const reply = this.storage.kv.get<Reply>(this.prefix(slot) + id)
        return reply?.acknowledged && reply.recipient === recipient ? { id, packet: reply.packet } : null
    }

    prune(now = Date.now()) {
        for (const [key, mailbox] of this.mailboxes()) if (mailbox.expiresAt <= now) this.remove(key)
    }
    deadlines() { return this.mailboxes().map(([, mailbox]) => mailbox.expiresAt) }
    clear() { for (const [key] of this.mailboxes()) this.remove(key) }

    private mailbox(slot: string) {
        const mailbox = this.storage.kv.get<Mailbox>(mailboxPrefix + slot)
        return mailbox && mailbox.expiresAt > Date.now() ? mailbox : null
    }
    private mailboxes() { return [...this.storage.kv.list<Mailbox>({ prefix: mailboxPrefix })] }
    private prefix(slot: string) { return `${replyPrefix + slot}:` }
    private replies(slot: string) { return [...this.storage.kv.list<Reply>({ prefix: this.prefix(slot) })] }
    private remove(key: string) {
        for (const [replyKey] of this.replies(key.slice(mailboxPrefix.length))) this.storage.kv.delete(replyKey)
        this.storage.kv.delete(key)
    }
}
