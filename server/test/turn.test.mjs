import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { callTestCredential, room, offer, provider, makeRuntime } from './support/runtime.mjs';
const call = async (runtime, path, body, method = 'POST', credential) => runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/${path}`, {
    method, headers: { Authorization: `Bearer ${credential ?? await callTestCredential(runtime)}`, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const leaseID = 'test-attempt-1';

test('TURN preflight is quota guarded, owned, idempotent and revoked on disconnect', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/alice', { leaseID }, 'POST', 'bad')).status, 401);
        assert.equal(provider.requests.length, 0);
        const first = await call(runtime, 'ice/alice', { leaseID });
        assert.equal(first.status, 200);
        const ice = await first.json();
        assert.ok(ice.iceServers.some(s => s.urls.some(u => u.startsWith('turn:'))));
        assert.equal(JSON.stringify(ice).includes('test-turn-secret'), false);
        await call(runtime, 'ice/alice', { leaseID });
        assert.equal(provider.requests.filter(r => r.url.includes('generate-ice-servers')).length, 1);
        assert.equal((await call(runtime, 'ice/alice', { leaseID: 'old-attempt' }, 'DELETE')).status, 409);
        const joined = await call(runtime, 'join', { participantId: 'alice', offer, iceLeaseID: leaseID });
        assert.equal(joined.status, 200);
        const lease = await joined.json();
        assert.equal((await call(runtime, `sessions/${lease.sessionId}`, undefined, 'DELETE')).status, 200);
        assert.ok(provider.requests.some(r => r.url.endsWith('/revoke')));
    } finally { await runtime.dispose(); }
});

test('pausing Internet calls leaves only owned session and preparation cleanup available', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-call-pause-'));
    const config = {
        TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret'
    };
    let runtime = await makeRuntime(config, { storageDirectory });
    try {
        const waiting = await callTestCredential(runtime, 'waiting-rider');
        const other = await callTestCredential(runtime, 'other-rider');
        assert.equal((await call(runtime, 'ice/call', { leaseID })).status, 200);
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'POST', waiting)).status, 200);
        const joined = await call(runtime, 'join', { participantId: 'call', offer, iceLeaseID: leaseID });
        assert.equal(joined.status, 200);
        const session = `sessions/${(await joined.json()).sessionId}`;
        await runtime.dispose();
        const paused = { ...config, SERVICE_ENABLED: 'false', TURN_ENABLED: 'false' };
        const withoutSfu = { ...paused, CLOUDFLARE_SFU_APP_SECRET: '' };
        runtime = await makeRuntime(withoutSfu, { storageDirectory });

        const before = provider.requests.length;
        assert.equal((await call(runtime, 'join', { participantId: 'new', offer })).status, 503);
        assert.equal((await call(runtime, 'ice/new', { leaseID })).status, 503);
        assert.equal((await call(runtime, `${session}/renew`, {})).status, 503);
        assert.equal((await call(runtime, `${session}/renew`, {}, 'DELETE')).status, 503);
        assert.equal((await call(runtime, session, undefined, 'DELETE')).status, 503);
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE', 'unregistered')).status, 401);
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE', other)).status, 403);
        assert.equal((await call(runtime, 'ice/waiting', { leaseID: 'older-attempt' }, 'DELETE', waiting)).status, 409);
        assert.equal(provider.requests.length, before);
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE', waiting)).status, 200);
        assert.equal(provider.requests.length, before + 1);
        assert.ok(provider.requests.at(-1)?.url.endsWith('/revoke'));
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE', waiting)).status, 200);
        assert.equal(provider.requests.length, before + 1);

        await runtime.dispose();
        runtime = await makeRuntime(paused, { storageDirectory });
        assert.equal((await call(runtime, session, undefined, 'DELETE', 'unregistered')).status, 401);
        assert.equal((await call(runtime, session, undefined, 'DELETE', other)).status, 403);
        assert.equal((await call(runtime, session, undefined, 'DELETE')).status, 200);
        const cleanup = provider.requests.slice(before);
        assert.equal(cleanup.filter(r => r.url.endsWith('/revoke')).length, 2);
        assert.equal(cleanup.filter(r => r.url.endsWith('/datachannels/close')).length, 1);
        assert.ok(cleanup.every(r => r.method === 'GET' || r.url.endsWith('/revoke') || r.url.endsWith('/datachannels/close')));
    } finally {
        await runtime.dispose();
        await rm(storageDirectory, { recursive: true, force: true });
    }
});

test('TURN cancellation keeps its pending lease without sending when the TURN token is missing', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-turn-paused-retry-'));
    const config = { TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
    let runtime = await makeRuntime(config, { storageDirectory });
    try {
        assert.equal((await call(runtime, 'ice/waiting', { leaseID })).status, 200);
        await runtime.dispose();
        const paused = { ...config, SERVICE_ENABLED: 'false', TURN_ENABLED: 'false', CLOUDFLARE_SFU_APP_SECRET: '' };
        runtime = await makeRuntime({ ...paused, CLOUDFLARE_TURN_API_TOKEN: '' }, { storageDirectory });

        const before = provider.requests.length;
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE')).status, 502);
        assert.equal(provider.requests.length, before);

        await runtime.dispose();
        runtime = await makeRuntime(paused, { storageDirectory });
        assert.equal((await call(runtime, 'ice/waiting', { leaseID }, 'DELETE')).status, 200);
        assert.equal(provider.requests.length, before + 1);
        assert.ok(provider.requests.at(-1)?.url.endsWith('/revoke'));
    } finally {
        await runtime.dispose();
        await rm(storageDirectory, { recursive: true, force: true });
    }
});

test('TURN preflight rejects malformed provider credentials without returning or caching them', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    try {
        provider.turnServers = [{ urls: ['turn:relay.example.invalid'], username: 'fixture', credential: { invalid: true } }];
        const failure = await call(runtime, 'ice/alice', { leaseID });
        assert.equal(failure.status, 502);
        assert.deepEqual(await failure.json(), { error: 'SFU operation failed' });
        delete provider.turnServers;
        assert.equal((await call(runtime, 'ice/alice', { leaseID })).status, 200);
    } finally { delete provider.turnServers; await runtime.dispose(); }
});

test('TURN preflight cannot exceed quota or silently fall back when misconfigured', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', MONTHLY_PARTICIPANT_SECONDS: '600' });
    try {
        assert.equal((await call(runtime, 'ice/a', { leaseID })).status, 200);
        const count = provider.requests.length;
        const other = await callTestCredential(runtime, 'other-rider');
        assert.equal((await call(runtime, 'ice/b', { leaseID: 'another' }, 'POST', other)).status, 429);
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, 'ice/a', { leaseID }, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
    const broken = await makeRuntime({ TURN_ENABLED: 'true' });
    try { assert.equal((await call(broken, 'ice/a', { leaseID })).status, 503); }
    finally { await broken.dispose(); }
});


test('TURN renewal keeps the SFU session and retires all issued credentials at disconnect', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', LEASE_SECONDS: '4' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/a', { leaseID })).status, 200);
        const lease = await (await call(runtime, 'join', { participantId: 'a', offer, iceLeaseID: leaseID })).json();
        await new Promise(resolve => setTimeout(resolve, 2100));
        const renewed = await (await call(runtime, `sessions/${lease.sessionId}/renew`, {})).json();
        assert.equal(renewed.sessionId, lease.sessionId);
        assert.ok(renewed.iceServers.some(s => s.username));
        const issues = provider.requests.filter(r => r.url.includes('/generate-ice-servers'));
        assert.equal(issues.length, 2);
        assert.ok(issues.every(r => r.body.ttl <= 8));
        assert.equal(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length, 1);
        assert.equal((await call(runtime, `sessions/${lease.sessionId}`, undefined, 'DELETE')).status, 200);
        assert.equal(provider.requests.filter(r => r.url.endsWith('/revoke')).length, 2);
    } finally { await runtime.dispose(); }
});

test('abandoned preflight expires without creating an SFU session', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret', LEASE_SECONDS: '1' });
    try {
        provider.requests = [];
        assert.equal((await call(runtime, 'ice/abandoned', { leaseID })).status, 200);
        await new Promise(resolve => setTimeout(resolve, 2200));
        assert.equal((await call(runtime, 'ice/abandoned', { leaseID: 'next-attempt' })).status, 200);
        assert.equal(provider.requests.some(r => r.url.endsWith('/sessions/new')), false);
    } finally { await runtime.dispose(); }
});


for (const failingProvider of ['TURN', 'SFU']) {
    test(`cleanup after ${failingProvider} failure retries without caching the TURN password`, async () => {
        const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-turn-retry-'));
        const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' }, { storageDirectory });
        try {
            const issued = await call(runtime, 'ice/retry', { leaseID });
            assert.equal(issued.status, 200);
            const { iceServers } = await issued.json();
            const credential = iceServers.find(server => server.credential);
            assert.ok(credential);
            let path = 'ice/retry';
            let body = { leaseID };
            if (failingProvider === 'SFU') {
                const joined = await call(runtime, 'join', { participantId: 'retry', offer, iceLeaseID: leaseID });
                assert.equal(joined.status, 200);
                path = `sessions/${(await joined.json()).sessionId}`;
                body = undefined;
            }
            const files = await readdir(storageDirectory, { recursive: true });
            const sqlite = files.find(path => path.includes('SignalingRoom') && /^[0-9a-f]{64}\.sqlite$/.test(basename(path)));
            assert.ok(sqlite, 'Room storage must exist');
            const database = new DatabaseSync(join(storageDirectory, sqlite), { readOnly: true });
            try {
                // Read the current row through SQLite so old pages do not count as retained values.
                const read = database.prepare('SELECT instr(value, CAST(? AS BLOB)) AS retained FROM _cf_KV WHERE CAST(key AS TEXT) = ?');
                assert.ok(read.get(credential.credential, 'ice:retry')?.retained > 0, 'Active ICE response must be cached');
                provider.revokeFails = failingProvider === 'TURN';
                provider.upstreamFails = failingProvider === 'SFU';
                assert.equal((await call(runtime, path, body, 'DELETE')).status, 502);
                assert.equal(read.get(credential.credential, 'ice:retry')?.retained, 0, 'Only the information needed to retry should remain');
            } finally { database.close(); }
            const failedRequest = provider.requests.at(-1);
            assert.ok(failedRequest?.url.endsWith(failingProvider === 'TURN' ? '/revoke' : path));
            const beforeRetry = provider.requests.length;
            provider.revokeFails = false;
            provider.upstreamFails = false;
            await new Promise(resolve => setTimeout(resolve, 1800));
            const requests = provider.requests.slice(beforeRetry);
            assert.ok(requests.some(request => request.url === failedRequest.url));
            assert.ok(requests.some(request => request.url.endsWith(`/credentials/${credential.username}/revoke`)));
            assert.equal((await call(runtime, 'ice/retry', { leaseID: 'new-attempt' })).status, 200);
        } finally {
            provider.revokeFails = false;
            provider.upstreamFails = false;
            await runtime.dispose();
            await rm(storageDirectory, { recursive: true, force: true });
        }
    });
}


test('orphan credential cleanup does not serialize upstream delays across participants', async () => {
    const runtime = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' });
    let active = 0, peak = 0;
    try {
        const peers = ['orphan-a', 'orphan-b'];
        const ice = async (peer, attempt, method = 'POST') =>
            call(runtime, `ice/${peer}`, { leaseID: attempt }, method, await callTestCredential(runtime, peer));
        for (const peer of peers) assert.equal((await ice(peer, leaseID)).status, 200);
        provider.revokeFails = true;
        for (const peer of peers) assert.equal((await ice(peer, leaseID, 'DELETE')).status, 502);
        provider.revokeFails = false;
        provider.onRevoke = async () => {
            peak = Math.max(peak, ++active);
            await new Promise(resolve => setTimeout(resolve, 200));
            active--;
        };
        await new Promise(resolve => setTimeout(resolve, 2200));
        assert.equal(peak, 2, 'alarm should overlap independent revocations');
        for (const peer of peers) assert.equal((await ice(peer, 'next-attempt')).status, 200);
    } finally { provider.revokeFails = false; provider.onRevoke = undefined; await runtime.dispose(); }
});
