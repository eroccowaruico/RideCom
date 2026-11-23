// The two existing fetch-based objects do not expose typed RPC methods.
// All new bindings and ordinary variables come from Wrangler's generated types.
export interface Env extends Omit<WorkerBindings, 'SIGNALING_ROOM' | 'USAGE_GUARD'> {
    SIGNALING_ROOM: DurableObjectNamespace
    USAGE_GUARD: DurableObjectNamespace
    CLOUDFLARE_SFU_APP_ID: string
    CLOUDFLARE_SFU_APP_SECRET: string
    CLOUDFLARE_TURN_KEY_ID?: string
    CLOUDFLARE_TURN_API_TOKEN?: string
    APPLE_SIGN_IN_PRIVATE_KEY?: string
    APPLE_SIGN_IN_KEY_ID?: string
    APPLE_TEAM_ID?: string
    APNS_PRIVATE_KEY?: string
    APNS_KEY_ID?: string
    DEVICE_IDENTITY_SIGNING_KEY?: string
    INVITATION_RELAY_KEY_SEED?: string
    DIRECT_CALL_RESTORE_RELAY_ENABLED?: string
    TEST_PREVIEW_MEDIA_TRIAL?: string
}
export interface Description { type: 'offer' | 'answer'; sdp: string }
export interface Member {
    id: string; owner: string; sessionId: string; expiresAt: number
    allocationPending?: boolean;
    channels: number[]; publishers?: { id: number; delivery: string }[]; subscriptions: { sessionId: string; id: number; peerId: string; delivery: string }[]
}
export function json(body: unknown, status = 200): Response {
    return Response.json(body, { status, headers: { 'Cache-Control': 'no-store' } })
}
export async function sha256Hex(value: string): Promise<string> {
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
}
export function limit(value: string | undefined, fallback: number, max: number): number {
    const n = Number(value)
    return Number.isSafeInteger(n) && n > 0 ? Math.min(n, max) : fallback
}
export function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null && !Array.isArray(value)
}
export async function readJSON(request: Request): Promise<Record<string, unknown>> {
    const reader = request.body?.getReader()
    if (!reader) throw new Error('body')
    let timer: ReturnType<typeof setTimeout> | null = null
    const deadline = new Promise<never>((_, reject) => {
        timer = setTimeout(() => {
            reject(new Error('body'))
            void reader.cancel().catch(() => {})
        }, 3000)
    })
    const chunks: Uint8Array[] = []; let size = 0
    try {
        await Promise.race([deadline, (async () => {
            for (;;) {
                const { done, value } = await reader.read(); if (done) break
                size += value.byteLength
                if (size > 64 * 1024) { void reader.cancel().catch(() => {}); throw new Error('body') }
                chunks.push(value)
            }
        })()])
    } finally { clearTimeout(timer); reader.releaseLock() }
    const bytes = new Uint8Array(size); let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    let result: unknown
    try { result = JSON.parse(new TextDecoder().decode(bytes)) } catch { throw new Error('body') }
    if (!isRecord(result)) throw new Error('body')
    return result
}
export function dataDescription(value: unknown, type: 'offer' | 'answer'): value is Description {
    if (!isRecord(value) || value.type !== type || typeof value.sdp !== 'string' || value.sdp.length > 48 * 1024) return false
    const media = value.sdp.split(/\r?\n/).filter((line: string) => line.startsWith('m='))
    return media.length === 1 && media[0].startsWith('m=application ') && value.sdp.split(/\r?\n/).includes('a=sctp-port:5000')
}
export async function sfu(env: Env, path: string, body?: unknown, method = 'POST'): Promise<Record<string, unknown>> {
    const response = await fetch(`https://rtc.live.cloudflare.com/v1/apps/${encodeURIComponent(env.CLOUDFLARE_SFU_APP_ID)}${path}`, {
        method, headers: { Authorization: `Bearer ${env.CLOUDFLARE_SFU_APP_SECRET}`, 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(8000)
    })
    if (response.status === 404 || response.status === 410) throw new Error('session-gone')
    if (!response.ok) throw new Error('upstream')
    const data: unknown = await response.json()
    if (!isRecord(data) || data.errorCode) throw new Error('upstream')
    if (data.tracks != null && (!Array.isArray(data.tracks)
        || !data.tracks.every((track: unknown) => isRecord(track) && !track.errorCode))) throw new Error('upstream')
    return data
}
