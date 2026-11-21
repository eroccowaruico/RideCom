// Local-only fixture for the macOS App/Worker E2E. No Apple, APNs or Cloudflare network access.
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { generateKeyPair, exportJWK, exportPKCS8, SignJWT } from 'jose';
import { makeRuntime } from './support/runtime.mjs';

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
process.chdir(serverRoot);
function bundleMatches() {
    if (!existsSync(resolve(serverRoot, 'dist/index.js.map'))) return false;
    const map = JSON.parse(readFileSync(resolve(serverRoot, 'dist/index.js.map'), 'utf8'));
    let count = 0;
    for (let i = 0; i < map.sources.length; i++) {
        const path = resolve(serverRoot, 'dist', map.sources[i]);
        if (path.startsWith(resolve(serverRoot, 'src') + '/')) {
            if (readFileSync(path, 'utf8') !== map.sourcesContent[i]) return false;
            count++;
        }
    }
    return count > 0;
}
if (!bundleMatches()) execFileSync(process.execPath, [resolve(serverRoot, 'node_modules/wrangler/bin/wrangler.js'), 'deploy', '--dry-run', '--outdir', 'dist'],
    { cwd: serverRoot, stdio: 'ignore', env: { ...process.env, CI: '1', WRANGLER_SEND_METRICS: 'false' } });
if (!bundleMatches()) throw new Error('Local Worker bundle source mismatch');
const apple = await generateKeyPair('RS256'), signing = await generateKeyPair('ES256', { extractable: true });
const applePublic = { ...await exportJWK(apple.publicKey), kid: 'group-app-fixture', alg: 'RS256' };
const runtime = await makeRuntime({ APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: 'fixture-app', CLIENT_TOKENS_JSON: '{}',
    NOTIFICATIONS_ENABLED: 'true', DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signing.privateKey)),
    INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url'),
    APNS_PRIVATE_KEY: await exportPKCS8(signing.privateKey), APNS_KEY_ID: 'fixturekey', APNS_TEAM_ID: 'fixtureteam',
    APNS_TOPIC: 'fixture-app', APNS_ENVIRONMENT: 'sandbox' }, { appleKeys: [applePublic], apns: async () => Response.json({}) });
const origin = 'https://delivery.test';
const dispatch = (path, method, body, token) => runtime.dispatchFetch(origin + path, { method,
    headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.77', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const server = createServer(async (request, response) => {
    try {
        const chunks = []; for await (const chunk of request) chunks.push(chunk);
        const data = Buffer.concat(chunks);
        if (request.url === '/fixture/register') {
            const input = JSON.parse(data.toString());
            const challenge = await (await dispatch('/api/auth/apple/challenge', 'POST', { deviceID: input.deviceID })).json();
            const identityToken = await new SignJWT({ sub: input.appleSubject ?? input.memberID, nonce: challenge.nonce }).setIssuer('https://appleid.apple.com')
                .setAudience('fixture-app').setIssuedAt().setExpirationTime('5m').setProtectedHeader({ alg: 'RS256', kid: applePublic.kid }).sign(apple.privateKey);
            const session = await dispatch('/api/auth/apple/session', 'POST', { challengeID: challenge.challengeID, identityToken });
            if (session.status !== 200) throw new Error('Fixture enrollment failed');
            const credential = await session.json();
            const proof = await dispatch('/api/auth/identity', 'POST', { memberID: input.memberID, deviceKey: input.deviceKey }, credential.accessToken);
            if (proof.status !== 200) throw new Error('Fixture certification failed');
            response.writeHead(200, { 'Content-Type': 'application/json' }); response.end(JSON.stringify({ credential, identity: await proof.json() }));
            return;
        }
        const upstream = await runtime.dispatchFetch(origin + request.url, { method: request.method,
            headers: { ...request.headers, 'CF-Connecting-IP': '192.0.2.77' }, ...(data.length ? { body: data } : {}) });
        response.writeHead(upstream.status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        response.end(Buffer.from(await upstream.arrayBuffer()));
    } catch { response.writeHead(500, { 'Content-Type': 'application/json' }); response.end('{"error":"local_fixture_failed"}'); }
});
server.listen(0, '127.0.0.1', () => writeFileSync(process.argv[2], JSON.stringify({ port: server.address().port })));
let stopping = false;
process.on('SIGTERM', async () => {
    if (stopping) return; stopping = true;
    const timeout = setTimeout(() => process.exit(1), 5000); timeout.unref();
    server.close(); await runtime.dispose(); process.exit(0);
});
