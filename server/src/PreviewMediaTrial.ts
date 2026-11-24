import { isRecord, readJSON, sha256Hex } from './types'

const fixedPreview = 'https://preview-ridecom.analog.workers.dev'
const lifetime = 20 * 60 * 1000
const digestPattern = /^[a-f0-9]{64}$/
const peerPattern = /^[a-zA-Z0-9_-]{1,60}$/
export const previewMediaTrialPrefix = 'preview-media.'

export async function previewMediaTrialOwner(
    request: Request, url: URL, credential: string, configuration: string | undefined,
    room: string | undefined, operation: string | undefined,
): Promise<string | undefined> {
    if (url.origin !== fixedPreview || !configuration ||
        !/^preview-media\.[a-zA-Z0-9_-]{43}$/.test(credential)) return undefined
    try {
        const grant: unknown = JSON.parse(configuration)
        if (!isRecord(grant) || typeof grant.room !== 'string' || !digestPattern.test(grant.room) ||
            typeof grant.issuedAt !== 'number' || !Number.isSafeInteger(grant.issuedAt) ||
            typeof grant.expiresAt !== 'number' || !Number.isSafeInteger(grant.expiresAt) ||
            !isRecord(grant.participants)) return undefined
        const now = Date.now()
        if (now < grant.issuedAt || now >= grant.expiresAt || grant.expiresAt - grant.issuedAt > lifetime) return undefined
        const participants = Object.entries(grant.participants)
        if (participants.length !== 2 || participants[0][1] === participants[1][1] ||
            !participants.every(([digest, peer]) => digestPattern.test(digest) && typeof peer === 'string' &&
                peerPattern.test(peer))) return undefined
        const peer = grant.participants[await sha256Hex(credential)]
        if (typeof peer !== 'string') return undefined
        const readsUsage = url.pathname === '/api/status' && request.method === 'GET'
        if (!readsUsage && (room !== grant.room || !operation)) return undefined
        if (operation?.startsWith('ice/') && operation !== `ice/${peer}`) return undefined
        if (operation === 'join' && (await readJSON(request.clone())).participantId !== peer) return undefined
        return `preview-media:${grant.room}:${peer}`
    } catch {
        return undefined
    }
}
