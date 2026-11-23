import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { unstable_readConfig } from 'wrangler';
import { callTestCredential, room, offer, makeRuntime } from './support/runtime.mjs';

test('production and Preview explicitly disable Worker logging and export', () => {
    const config = unstable_readConfig({ config: fileURLToPath(new URL('../wrangler.toml', import.meta.url)) });
    assert.ok(config.previews);
    assert.equal(config.logpush, false);
    assert.equal(config.previews.logpush ?? config.logpush, false);
    for (const observability of [config.observability, config.previews.observability ?? config.observability]) {
        assert.equal(observability?.enabled, false);
        assert.equal(observability.redact_query_string, true);
        assert.equal(observability.logs?.enabled, false);
        assert.equal(observability.logs.invocation_logs, false);
        assert.equal(observability.logs.persist, false);
        assert.deepEqual(observability.logs.destinations, []);
        assert.equal(observability.traces?.enabled, false);
        assert.equal(observability.traces.persist, false);
        assert.deepEqual(observability.traces.destinations, []);
    }
});

test('fixed Preview enables Internet call enrollment and TURN while notifications remain isolated', () => {
    const config = unstable_readConfig({ config: fileURLToPath(new URL('../wrangler.toml', import.meta.url)) });
    assert.ok(config.previews);
    for (const flag of ['APPLE_AUTH_ENABLED', 'SERVICE_ENABLED', 'TURN_ENABLED']) {
        assert.equal(config.vars[flag], 'true', flag);
        assert.equal(config.previews.vars[flag], 'true', flag);
    }
    assert.equal(config.vars.NOTIFICATIONS_ENABLED, 'true');
    assert.equal(config.previews.vars.NOTIFICATIONS_ENABLED, 'false');
    assert.equal(config.previews.vars.APNS_ENVIRONMENT, 'sandbox');
});

test('fixed Preview declares its own SFU and TURN references', () => {
    const config = unstable_readConfig({ config: fileURLToPath(new URL('../wrangler.toml', import.meta.url)) });
    assert.ok(config.previews);
    for (const variable of ['CLOUDFLARE_SFU_APP_ID', 'CLOUDFLARE_TURN_KEY_ID']) {
        assert.ok(config.previews.vars[variable], variable);
        assert.notEqual(config.previews.vars[variable], config.vars[variable], variable);
    }
});

test('join needs no display name', async () => {
    const runtime = await makeRuntime();
    try {
        const response = await runtime.dispatchFetch(`https://worker.test/api/rooms/${room}/join`, {
            method: 'POST', headers: { Authorization: `Bearer ${await callTestCredential(runtime)}` },
            body: JSON.stringify({ participantId: 'anonymous-rider', offer })
        });
        assert.equal(response.status, 200);
    } finally { await runtime.dispose(); }
});

test('extra display name is neither persisted nor broadcast to room peers', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-signaling-privacy-'));
    const runtime = await makeRuntime({}, { storageDirectory });
    try {
        const base = `https://worker.test/api/rooms/${room}`;
        const headers = { Authorization: `Bearer ${await callTestCredential(runtime)}` };
        const response = await runtime.dispatchFetch(`${base}/join`, {
            method: 'POST', headers,
            body: JSON.stringify({ participantId: 'opaque-peer', displayName: 'PrivateHumanName', offer })
        });
        assert.equal(response.status, 200);
        const { sessionId } = await response.json();
        assert.equal((await runtime.dispatchFetch(`${base}/sessions/${sessionId}/publish`, {
            method: 'POST', headers, body: '{}'
        })).status, 200);
        const files = await readdir(storageDirectory, { recursive: true });
        const roomFiles = files.filter(path => path.includes('SignalingRoom') && /\.sqlite(?:-wal)?$/.test(path));
        assert.ok(roomFiles.length > 0, 'Room storage must exist');
        // Include SQLite's WAL so uncheckpointed values cannot escape the check.
        const bytes = Buffer.concat(await Promise.all(roomFiles.map(path => readFile(join(storageDirectory, path)))));
        assert.ok(bytes.includes(Buffer.from('opaque-peer')), 'The persisted member must be inspected');
        assert.ok(!bytes.includes(Buffer.from('displayName')));
        assert.ok(!bytes.includes(Buffer.from('PrivateHumanName')));
        const socketResponse = await runtime.dispatchFetch(`${base}/sessions/${sessionId}/signal`, {
            headers: { ...headers, Upgrade: 'websocket' }
        });
        assert.equal(socketResponse.status, 101);
        const ws = socketResponse.webSocket;
        try {
            const next = new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error('No peer list')), 3000);
                ws.addEventListener('message', event => { clearTimeout(timer); resolve(JSON.parse(event.data)); }, { once: true });
            });
            ws.accept();
            assert.deepEqual(await next, { type: 'peers', peers: [{ id: 'opaque-peer', sessionId }] });
        } finally { ws.close(); }
    } finally {
        await runtime.dispose();
        await rm(storageDirectory, { recursive: true, force: true });
    }
});
