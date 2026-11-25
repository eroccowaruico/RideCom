import { tracing, WorkerEntrypoint } from 'cloudflare:workers'
import { apnsTimeoutMs, sandboxAPNSSenderURL } from './SandboxAPNSTransport'
import { isRecord, readJSON } from './types'

export default {
    fetch(): Response { return new Response(null, { status: 404 }) },
}

export class SandboxAPNSSender extends WorkerEntrypoint {
    async fetch(request: Request): Promise<Response> {
        if (request.url !== sandboxAPNSSenderURL) return new Response(null, { status: 404 })
        if (tracing.getActiveSpan()?.isTraced !== false) return new Response(null, { status: 503 })
        if (request.method === 'GET') return new Response(null, { status: 204 })
        if (request.method !== 'POST') return new Response(null, { status: 405 })
        try {
            const { token, headers, body } = await readJSON(request)
            if (typeof token !== 'string' || !/^(?:[a-f0-9]{2}){1,2048}$/.test(token)
                || !isRecord(headers) || typeof body !== 'string') return new Response(null, { status: 400 })
            const outboundHeaders = new Headers()
            for (const [key, value] of Object.entries(headers)) {
                if (typeof value !== 'string') return new Response(null, { status: 400 })
                outboundHeaders.set(key, value)
            }
            const upstream = await fetch(`https://api.sandbox.push.apple.com/3/device/${token}`, {
                method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(apnsTimeoutMs),
                headers: outboundHeaders, body,
            })
            await upstream.body?.cancel()
            return new Response(null, { status: upstream.status })
        } catch { return new Response(null, { status: 503 }) }
    }
}
