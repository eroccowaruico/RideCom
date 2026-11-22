const prefix = 'direct-restore-device:'
const capacity = 64
export const restoreDeviceLifetime = 86_400_000
export const restoreDeviceClockTolerance = 60_000

export interface DirectRestoreDevicePublication {
    deviceID: string
    sessionBinding: string
    issuedAt: number
    expiresAt: number
    packet: string
}

type Entry = DirectRestoreDevicePublication | { deviceID: string; expiresAt: number; packet: null }

/** Encrypted certificates scoped to one publisher account and one authorized reader. */
export class AccountDirectRestoreDevices {
    constructor(private readonly storage: DurableObjectStorage) {}

    publish(scope: string, value: DirectRestoreDevicePublication) {
        if (value.expiresAt <= Date.now()) return 'expired'
        this.prune()
        const old = this.current(scope)
        if (old) {
            if (old.deviceID !== value.deviceID || old.packet === null) return 'conflict'
            if (old.issuedAt >= value.issuedAt) {
                return old.issuedAt === value.issuedAt && old.sessionBinding === value.sessionBinding
                    && old.expiresAt === value.expiresAt && old.packet === value.packet ? 'stored' : 'conflict'
            }
        } else if (this.entries().length >= capacity) return 'limited'
        this.storage.kv.put<Entry>(prefix + scope, value)
        return 'stored'
    }

    revoke(scope: string, deviceID: string) {
        this.prune()
        const old = this.current(scope)
        if (old && old.deviceID !== deviceID) return 'conflict'
        if (old?.packet === null) return { expiresAt: old.expiresAt }
        if (!old && this.entries().length >= capacity) return 'limited'
        // A DELETE may overtake its PUT. Cover the expiry of any publication already signed.
        const expiresAt = Date.now() + restoreDeviceLifetime + restoreDeviceClockTolerance
        this.storage.kv.put<Entry>(prefix + scope, { deviceID, expiresAt, packet: null })
        return { expiresAt }
    }

    publication(scope: string): DirectRestoreDevicePublication | null {
        const value = this.current(scope)
        return value?.packet != null ? value : null
    }

    private current(scope: string) {
        const value = this.storage.kv.get<Entry>(prefix + scope)
        return value && value.expiresAt > Date.now() ? value : null
    }

    private entries() { return [...this.storage.kv.list<Entry>({ prefix })] }
    deadlines() { return this.entries().map(([, entry]) => entry.expiresAt) }
    clear() { for (const [key] of this.entries()) this.storage.kv.delete(key) }
    prune() {
        const now = Date.now()
        for (const [key, entry] of this.entries()) if (entry.expiresAt <= now) this.storage.kv.delete(key)
    }
}
