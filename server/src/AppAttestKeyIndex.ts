import { DurableObject } from 'cloudflare:workers'

interface Claim { owner: string; id: string; expiresAt: number }

/** One SQLite object per verified public key and App Attest environment. */
export class AppAttestKeyIndex extends DurableObject {
    async claim(owner: string, id: string, expiresAt: number): Promise<boolean> {
        const stored = this.ctx.storage.kv.get<Claim>('claim')
        if (stored && stored.expiresAt > Date.now()) return stored.owner === owner && stored.id === id
        if (!Number.isSafeInteger(expiresAt) || expiresAt <= Date.now() || expiresAt > Date.now() + 30 * 86400000) return false
        this.ctx.storage.kv.put('claim', { owner, id, expiresAt })
        await this.ctx.storage.setAlarm(expiresAt)
        return true
    }

    release(owner: string, id: string): void {
        const stored = this.ctx.storage.kv.get<Claim>('claim')
        if (stored?.owner === owner && stored.id === id) this.ctx.storage.kv.delete('claim')
    }

    async alarm(): Promise<void> {
        const stored = this.ctx.storage.kv.get<Claim>('claim')
        if (!stored) return
        if (stored.expiresAt <= Date.now()) this.ctx.storage.kv.delete('claim')
        else await this.ctx.storage.setAlarm(stored.expiresAt)
    }
}
