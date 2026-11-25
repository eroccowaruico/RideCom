import { tracing } from 'cloudflare:workers'
import type { Env } from './types'

export const sandboxAPNSSenderURL = 'https://sandbox-apns.internal/'
export const apnsTimeoutMs = 8000

export function requiresSandboxTransport(environment: string): boolean {
    return environment === 'sandbox' && tracing.getActiveSpan()?.isTraced !== false
}

export async function sandboxTransportReady(env: Env): Promise<boolean> {
    try {
        return (await env.TEST_PREVIEW_SANDBOX_APNS_SENDER?.fetch(sandboxAPNSSenderURL))?.status === 204
    }
    catch { return false }
}

export async function sendViaSandboxTransport(
    env: Env, token: string, headers: Record<string, string>, body: string,
): Promise<Response | undefined> {
    // The traced caller invokes a fixed URL. The device token and provider JWT only travel in the body.
    return env.TEST_PREVIEW_SANDBOX_APNS_SENDER?.fetch(sandboxAPNSSenderURL, {
        method: 'POST', body: JSON.stringify({ token, headers, body }),
    })
}
