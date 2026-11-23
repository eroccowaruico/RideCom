// Run real Swift signaling clients through workerd HTTP, WebSocket and SQLite DOs.
// Uses local device credentials and a mock SFU. No microphone or Apple sign-in.
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { makeRuntime, callTestCredential, provider } from './support/runtime.mjs';
const runtime = await makeRuntime({ LEASE_SECONDS: '4' });
try {
    const origin = (await runtime.ready).origin;
    const alice = await callTestCredential(runtime);
    const bob = await callTestCredential(runtime, 'other-rider');
    const code = await new Promise((resolve, reject) => {
        const args = ['test', '--package-path', '../RideIntercom/packages/RTC', '--filter', 'WorkerPairTests'];
        if (process.env.RIDEINTERCOM_PAIR_SANITIZER) args.push(`--sanitize=${process.env.RIDEINTERCOM_PAIR_SANITIZER}`);
        const child = spawn('swift', args, {
            stdio: 'inherit', env: { ...process.env, RIDEINTERCOM_PAIR_URL: origin,
                RIDEINTERCOM_PAIR_TOKEN_A: alice, RIDEINTERCOM_PAIR_TOKEN_B: bob }
        });
        const timer = setTimeout(() => child.kill('SIGTERM'), 120000);
        child.on('error', reject);
        child.on('exit', code => { clearTimeout(timer); resolve(code); });
    });
    assert.equal(code, 0, 'Swift pair test failed or timed out');
    assert.ok(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length >= 3);
    assert.ok(provider.requests.some(r => r.url.endsWith('/datachannels/close')), 'Rejoin must release old subscription channels');
    console.log('PAIR PASS: real Swift HTTP/WS + Worker/DO, external SFU mocked; audio media unverified.');
} finally { await runtime.dispose(); }
