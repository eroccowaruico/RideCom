import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import { makeRuntime, offer, provider, room } from './support/runtime.mjs';

const preview = 'https://preview-rideintercom.analog.workers.dev';
const tokens = ['a', 'b'].map(value => `preview-media.${value.repeat(43)}`);
const digests = tokens.map(value => createHash('sha256').update(value).digest('hex'));
const now = 1_700_000_000_000;
const grant = {
    room, issuedAt: now - 1000, expiresAt: now + 1000,
    participants: { [digests[0]]: 'media-a', [digests[1]]: 'media-b' }
};
const roomPath = `/api/rooms/${room}`;

function call(runtime, path, { origin = preview, method = 'GET', token = tokens[0], body } = {}) {
    return runtime.dispatchFetch(origin + path, {
        method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
}

test('two Preview credentials are scoped to the room and cannot manage each other’s sessions', async t => {
    const runtime = await makeRuntime({ PREVIEW_MEDIA_TRIAL: JSON.stringify(grant) }, { fixedNowMs: now });
    t.after(() => runtime.dispose());
    provider.requests = [];
    const join = (participantId, token = tokens[0]) =>
        call(runtime, `${roomPath}/join`, { method: 'POST', token, body: { participantId, offer } });
    assert.equal((await call(runtime, '/api/status')).status, 200);
    assert.equal((await call(runtime, '/api/status', { origin: 'https://rideintercom.analog.workers.dev' })).status, 401);
    assert.equal((await call(runtime, '/api/status', { origin: 'https://other-preview.workers.dev' })).status, 401);
    assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/join`, {
        method: 'POST', body: { participantId: 'media-a', offer }
    })).status, 401);
    assert.equal((await call(runtime, `${roomPath}/ice/media-b`, { method: 'POST', body: { leaseID: 'ice' } })).status, 401);
    assert.equal((await join('media-b')).status, 401);
    assert.equal((await join('media-a', 'preview-media.' + 'z'.repeat(43))).status, 401);
    assert.equal(provider.requests.length, 0);
    const a = await join('media-a');
    const b = await join('media-b', tokens[1]);
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    const aSession = `${roomPath}/sessions/${(await a.json()).sessionId}`;
    const bSession = `${roomPath}/sessions/${(await b.json()).sessionId}`;
    assert.equal((await call(runtime, aSession, { method: 'DELETE', token: tokens[1] })).status, 403);
    assert.equal((await call(runtime, aSession, { method: 'DELETE' })).status, 200);
    assert.equal((await call(runtime, bSession, { method: 'DELETE', token: tokens[1] })).status, 200);
});

test('absent, expired, future and oversized Preview grants fail closed without legacy fallback', async t => {
    const variants = [
        undefined, { ...grant, expiresAt: now }, { ...grant, issuedAt: now + 1 },
        { ...grant, expiresAt: now + 21 * 60 * 1000 },
        { ...grant, participants: { [digests[0]]: 'media-a', [digests[1]]: 'media-a' } }
    ];
    for (const value of variants) {
        const runtime = await makeRuntime({
            PREVIEW_MEDIA_TRIAL: JSON.stringify(value) ?? '',
            CLIENT_TOKENS_JSON: JSON.stringify({ [digests[0]]: 'must-not-fallback' })
        }, { fixedNowMs: now });
        try {
            assert.equal((await call(runtime, '/api/status')).status, 401);
        } finally { await runtime.dispose(); }
    }
});
