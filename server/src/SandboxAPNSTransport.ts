import { tracing } from 'cloudflare:workers'
import { sha256Hex, type Env } from './types'

const endpoint = 'https://sandbox-apns.internal/'
export const apnsTimeoutMs = 8000
const source = `
import { tracing } from 'cloudflare:workers';
export default {
    async fetch(request) {
        if (tracing.getActiveSpan()?.isTraced !== false) return new Response(null, { status: 503 });
        if (request.method === 'GET') return new Response(null, { status: 204 });
        if (request.method !== 'POST') return new Response(null, { status: 405 });
        try {
            const { token, headers, body } = await request.json();
            if (typeof token !== 'string' || !/^(?:[a-f0-9]{2}){1,2048}$/.test(token)) {
                return new Response(null, { status: 400 });
            }
            const upstream = await fetch('https://api.sandbox.push.apple.com/3/device/' + token, {
                method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(${apnsTimeoutMs}), headers, body
            });
            await upstream.body?.cancel();
            return new Response(null, { status: upstream.status });
        } catch {
            return new Response(null, { status: 503 });
        }
    }
};
`

const workerCode: WorkerLoaderWorkerCode = {
    compatibilityDate: '2026-11-17', mainModule: 'sandbox-apns.js',
    modules: { 'sandbox-apns.js': source },
}
let workerID: Promise<string> | undefined

async function sender(env: Env): Promise<Fetcher | undefined> {
    const loader = env.TEST_PREVIEW_SANDBOX_APNS_LOADER
    if (!loader) return undefined
    // Cache the same code together, but never reuse its ID for changed code or settings.
    workerID ??= sha256Hex(JSON.stringify(workerCode)).then(digest => `sandbox-apns-${digest}`)
    return loader.get(await workerID, () => workerCode).getEntrypoint()
}

export function requiresSandboxTransport(environment: string): boolean {
    return environment === 'sandbox' && tracing.getActiveSpan()?.isTraced !== false
}

export async function sandboxTransportReady(env: Env): Promise<boolean> {
    try {
        const worker = await sender(env)
        return (await worker?.fetch(endpoint))?.status === 204
    }
    catch { return false }
}

export async function sendViaSandboxTransport(
    env: Env, token: string, headers: Record<string, string>, body: string,
): Promise<Response | undefined> {
    // The traced caller invokes a fixed URL. The device token and provider JWT only travel in the body.
    const worker = await sender(env)
    return worker?.fetch(endpoint, { method: 'POST', body: JSON.stringify({ token, headers, body }) })
}
