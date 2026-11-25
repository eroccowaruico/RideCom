// Run real Swift signaling clients through workerd HTTP, WebSocket and SQLite DOs.
// Apple proof, TURN, and SFU providers are local fixtures. No real accounts or audio hardware.
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { watch } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import { unstable_readConfig } from 'wrangler';
import { callTestCredential, makeRuntime, provider } from './support/runtime.mjs';

const { APPLE_CLIENT_ID: audience } = unstable_readConfig({ config: 'wrangler.toml' }).vars;
assert.equal(typeof audience, 'string');
const apple = await generateKeyPair('RS256');
const publicKey = { ...await exportJWK(apple.publicKey), kid: 'call-pair-fixture', alg: 'RS256' };
const rejectedSignalRoom = 'f'.repeat(64);
const runtime = await makeRuntime({
    APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: audience,
    TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret',
    LEASE_SECONDS: '4',
}, { appleKeys: [publicKey], rejectSignalForRoom: rejectedSignalRoom });

async function enroll(subject) {
    const post = (path, body) => runtime.dispatchFetch(`https://worker.test/api/auth/apple/${path}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10' },
        body: JSON.stringify(body),
    });
    const deviceID = randomUUID();
    const challengeResponse = await post('challenge', { deviceID });
    assert.equal(challengeResponse.status, 200, 'Request an Apple login challenge');
    const { challengeID, nonce } = await challengeResponse.json();
    const identityToken = await new SignJWT({ nonce }).setSubject(subject).setAudience(audience)
        .setIssuer('https://appleid.apple.com').setIssuedAt().setExpirationTime('5m')
        .setProtectedHeader({ alg: 'RS256', kid: publicKey.kid }).sign(apple.privateKey);
    const session = await post('session', { challengeID, identityToken });
    assert.equal(session.status, 200, 'Exchange the Apple proof for a device credential');
    const credential = await session.json();
    assert.equal(credential.deviceID, deviceID);
    return credential;
}

let expiryRuntime;
let clockDirectory;
try {
    const origin = (await runtime.ready).origin;
    const alice = await enroll('call-pair-first'), bob = await enroll('call-pair-second');
    assert.ok(alice.userID !== bob.userID, 'Internet calling requires a distinct account for each endpoint');
    expiryRuntime = await makeRuntime({ LEASE_SECONDS: '4' }, { adjustableClock: true, fixedNowMs: Date.now() });
    const expiryOrigin = (await expiryRuntime.ready).origin;
    const expiring = await callTestCredential(expiryRuntime, 'expiring-pair-first');
    await expiryRuntime.advanceClock(30 * 86400000 - 1000);
    const staying = await callTestCredential(expiryRuntime, 'expiring-pair-second');
    const arriving = await callTestCredential(expiryRuntime, 'expiring-pair-third');
    clockDirectory = await mkdtemp(join(tmpdir(), 'ridecom-pair-clock-'));
    const clockSignal = join(clockDirectory, 'advance');
    const code = await new Promise((resolve, reject) => {
        const args = ['test', '--package-path', '../RideIntercom/packages/RTC', '--filter', 'WorkerPairTests'];
        if (process.env.RIDEINTERCOM_PAIR_SANITIZER) args.push(`--sanitize=${process.env.RIDEINTERCOM_PAIR_SANITIZER}`);
        const clockWatcher = watch(clockDirectory, (event, filename) => {
            if (event !== 'rename' || filename !== 'advance') return;
            clockWatcher.close();
            expiryRuntime.advanceClock(1001).catch(error => { child.kill('SIGTERM'); reject(error); });
        });
        const child = spawn('swift', args, {
            stdio: 'inherit', env: { ...process.env, RIDEINTERCOM_PAIR_URL: origin,
                RIDEINTERCOM_PAIR_REJECTED_SIGNAL_ROOM: rejectedSignalRoom,
                RIDEINTERCOM_PAIR_TOKEN_A: alice.accessToken, RIDEINTERCOM_PAIR_TOKEN_B: bob.accessToken,
                RIDEINTERCOM_PAIR_EXPIRY_URL: expiryOrigin, RIDEINTERCOM_PAIR_EXPIRING: expiring,
                RIDEINTERCOM_PAIR_STAYING: staying, RIDEINTERCOM_PAIR_ARRIVING: arriving,
                RIDEINTERCOM_PAIR_CLOCK_SIGNAL: clockSignal }
        });
        const timer = setTimeout(() => child.kill('SIGTERM'), 120000);
        clockWatcher.on('error', error => { child.kill('SIGTERM'); reject(error); });
        child.on('error', error => { clockWatcher.close(); clearTimeout(timer); reject(error); });
        child.on('exit', code => { clockWatcher.close(); clearTimeout(timer); resolve(code); });
    });
    assert.equal(code, 0, 'Swift pair test failed or timed out');
    assert.ok(provider.requests.filter(r => r.url.endsWith('/generate-ice-servers')).length >= 3,
        'The two initial connections and rejoin must obtain TURN credentials');
    assert.ok(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length >= 3);
    assert.ok(provider.requests.some(r => r.url.endsWith('/datachannels/close')), 'Rejoin must release old subscription channels');
    console.log('PAIR PASS: local Apple proof and TURN issuance, Swift HTTP/WS + Worker/DO; media providers mocked.');
} finally {
    await Promise.all([
        runtime.dispose(), expiryRuntime?.dispose(),
        clockDirectory && rm(clockDirectory, { recursive: true, force: true })
    ]);
}
