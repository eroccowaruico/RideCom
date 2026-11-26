import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { callTestCredential, room, offer, provider, makeRuntime } from './support/runtime.mjs';
let runtime;
before(async () => { runtime = await makeRuntime(); });
after(async () => { await runtime?.dispose(); });
const call = async (path, body, method = 'POST', instance = runtime, credential) => instance.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { Authorization: `Bearer ${credential ?? await callTestCredential(instance)}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const join = (id, target = room, instance = runtime, credential) =>
    call(`/api/rooms/${target}/join`, { participantId: id, offer }, 'POST', instance, credential);
const confirm = (path, credential, peerIDs, instance, extraHeaders = {}) =>
    instance.dispatchFetch(`https://worker.test${path}/renew`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${credential}`, 'X-Established-Peer': peerIDs, ...extraHeaders }
    });

test('join rejects coerced identities and partial SCTP attribute matches before allocation', async () => {
    const instance = await makeRuntime();
    try {
        for (const body of [
            { participantId: 123, offer },
            { participantId: 'bad-port', offer: { ...offer, sdp: offer.sdp.replace('5000', '50000') } },
            { participantId: '', offer },
            { participantId: 'A\u0000B', offer },
            { participantId: 'x'.repeat(64), offer },
        ]) {
            assert.equal((await call(`/api/rooms/${room}/join`, body, 'POST', instance)).status, 400);
        }
        assert.equal((await call(`/api/rooms/${room}/join`,
            { participantId: 'valid-id', offer }, 'POST', instance)).status, 200);
    } finally { await instance.dispose(); }
});

test('WebSocket null is rejected with a policy close instead of an uncaught exception', async () => {
    const instance = await makeRuntime();
    try {
        const member = await (await join('null-message', room, instance)).json();
        const response = await instance.dispatchFetch(`https://worker.test/api/rooms/${room}/sessions/${member.sessionId}/signal`, {
            headers: { Authorization: `Bearer ${await callTestCredential(instance)}`, Upgrade: 'websocket' }
        });
        assert.equal(response.status, 101);
        const ws = response.webSocket; ws.accept();
        const closed = new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Invalid message was not closed')), 3000);
            ws.addEventListener('close', e => { clearTimeout(timer); resolve(e.code); }, { once: true });
        });
        ws.send('null');
        assert.equal(await closed, 1008);
    } finally { await instance.dispose(); }
});

test('eight participants join and publish while the ninth is refused', async () => {
    const instance = await makeRuntime({ MAX_ROOM_PARTICIPANTS: '8' });
    try {
        for (let i = 0; i < 8; i++) {
            const credential = await callTestCredential(instance, `rider-${i}`);
            const response = await join(`rider-${i}`, room, instance, credential);
            assert.equal(response.status, 200);
            const member = await response.json();
            assert.equal((await call(`/api/rooms/${room}/sessions/${member.sessionId}/publish`, {}, 'POST', instance, credential)).status, 200);
        }
        assert.equal((await join('ninth', room, instance)).status, 429);
    } finally { await instance.dispose(); }
});

test('a stalled request body expires and does not keep the room locked', async () => {
    const instance = await makeRuntime();
    const body = new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode('{')); } });
    try {
        const response = await instance.dispatchFetch(`https://worker.test/api/rooms/${room}/join`, {
            method: 'POST', headers: { Authorization: `Bearer ${await callTestCredential(instance)}`, 'Content-Type': 'application/json' },
            body, duplex: 'half', signal: AbortSignal.timeout(6000)
        });
        assert.equal(response.status, 400);
        assert.equal((await join('after-stall', room, instance)).status, 200);
    } finally { await instance.dispose(); }
});

test('a legacy token is rejected even if its old registry is still configured', async t => {
    const legacy = 'retired-test-credential';
    const digest = createHash('sha256').update(legacy).digest('hex');
    const instance = await makeRuntime({ CLIENT_TOKENS_JSON: JSON.stringify({ [digest]: 'retired' }) });
    t.after(() => instance.dispose());
    assert.equal((await call('/api/status', undefined, 'GET', instance, legacy)).status, 401);
    assert.equal((await call('/api/status', undefined, 'GET', instance)).status, 200);
});

test('successful ICE preparation survives a temporary failure to remove an empty room from the account index', async t => {
    const now = Date.now();
    const instance = await makeRuntime({}, { adjustableClock: true, fixedNowMs: now, failFirstRoomDetach: true });
    t.after(() => instance.dispose());
    const credential = await callTestCredential(instance);
    const request = path => call(`/api/rooms/${path}/ice/first`, { leaseID: 'first' }, 'POST', instance, credential);

    const prepared = await request(room);
    assert.equal(prepared.status, 200);
    assert.equal((await prepared.json()).iceServers.length, 1);

    const rooms = await instance.getDurableObjectNamespace('SIGNALING_ROOM');
    const accounts = await instance.getDurableObjectNamespace('USER_ACCOUNT');
    const [, accountID, deviceID, secret] = credential.split('.');
    const account = accounts.get(accounts.idFromString(accountID));
    const { userID } = await account.authenticate(deviceID, createHash('sha256').update(secret).digest('hex'));
    for (let i = 0; i < 7; i++) assert.equal(await account.attachRoom(userID, rooms.idFromName(`fixture-${i}`).toString()), true);
    const nextRoom = 'b'.repeat(64);
    assert.equal((await request(nextRoom)).status, 403, 'The empty room is still in the account index');

    const pending = rooms.get(rooms.idFromName(room));
    const scheduledAlarm = async () => (await pending.fetch('https://fixture.test/scheduled-room-alarm')).json();
    assert.equal(await scheduledAlarm(), now + 30000);
    await instance.advanceClock(30000);
    assert.equal((await pending.fetch('https://fixture.test/run-room-alarm', { method: 'POST' })).status, 204);
    assert.equal((await request(nextRoom)).status, 200, 'The alarm frees the account index slot');
    assert.equal(await scheduledAlarm(), null);
    const joined = await join('first', nextRoom, instance, credential);
    assert.equal(joined.status, 200);
    const session = `/api/rooms/${nextRoom}/sessions/${(await joined.json()).sessionId}`;
    assert.equal((await call(session, undefined, 'DELETE', instance, credential)).status, 200);
});

test('successful TURN call termination survives a temporary failure to remove the room index', async t => {
    const instance = await makeRuntime({ TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn',
        CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' }, { failFirstRoomDetach: true });
    t.after(() => instance.dispose());
    const credential = await callTestCredential(instance);
    const participantId = 'first', iceLeaseID = 'first';
    const base = `/api/rooms/${room}`;
    assert.equal((await call(`${base}/ice/${participantId}`, { leaseID: iceLeaseID }, 'POST', instance, credential)).status, 200);
    const joined = await call(`${base}/join`, { participantId, iceLeaseID, offer }, 'POST', instance, credential);
    assert.equal(joined.status, 200);
    const session = `${base}/sessions/${(await joined.json()).sessionId}`;
    assert.equal((await call(session, undefined, 'DELETE', instance, credential)).status, 200);
    assert.equal((await call(session, {}, 'POST', instance, credential)).status, 404);
    assert.equal((await call(`${base}/ice/${participantId}`, { leaseID: 'next' }, 'POST', instance, credential)).status, 200);
    assert.equal((await call(`${base}/ice/${participantId}`, { leaseID: 'next' }, 'DELETE', instance, credential)).status, 200);
});

test('unauthenticated and malformed provider.requests never contact the provider', async () => {
    provider.requests = [];
    assert.equal((await runtime.dispatchFetch('https://worker.test/health')).status, 200);
    assert.equal((await call(`/api/rooms/${room}/join`, {}, 'POST', runtime, 'invalid')).status, 401);
    assert.equal((await call(`/api/rooms/${room}/join`, { participantId: 'x', offer: { ...offer, sdp: `${offer.sdp}m=video 9 RTP/AVP 96\r\n` } })).status, 400);
    assert.equal((await call('/api/rooms/guessable/join', {})).status, 400);
    assert.equal(provider.requests.length, 0);
});

async function prepareReciprocalSubscriptions(instance, id, path, credential, usesTurn = false) {
    const peer = await callTestCredential(instance, 'confirmation-partner');
    const iceLeaseID = 'confirmation-ice';
    if (usesTurn) {
        const ice = await call(`/api/rooms/${room}/ice/confirmation-partner`, { leaseID: iceLeaseID }, 'POST', instance, peer);
        assert.equal(ice.status, 200);
    }
    const joined = await call(`/api/rooms/${room}/join`, {
        participantId: 'confirmation-partner', offer, iceLeaseID,
    }, 'POST', instance, peer);
    assert.equal(joined.status, 200);
    const peerPath = `/api/rooms/${room}/sessions/${(await joined.json()).sessionId}`;
    assert.equal((await call(`${peerPath}/publish`, {}, 'POST', instance, peer)).status, 200);
    assert.equal((await call(`${path}/pull`, { peerIds: ['confirmation-partner'] }, 'POST', instance, credential)).status, 200);
    assert.equal((await call(`${peerPath}/pull`, { peerIds: [id] }, 'POST', instance, peer)).status, 200);
    return { path: peerPath, credential: peer };
}

async function establishWithPeer(instance, id, path, credential, usesTurn = false) {
    const peer = await prepareReciprocalSubscriptions(instance, id, path, credential, usesTurn);
    const response = await confirm(path, credential, 'confirmation-partner', instance);
    assert.equal(response.status, 200);
    const { establishedAt } = await response.json();
    assert.equal(typeof establishedAt, 'number');
    assert.equal((await call(peer.path, undefined, 'DELETE', instance, peer.credential)).status, 200);
    return establishedAt;
}

test('an ordinary call renewal survives a temporary failure to record its establishment', async t => {
    const initialTime = Date.now();
    const instance = await makeRuntime({}, {
        adjustableClock: true, fixedNowMs: initialTime, failFirstCallRenewalRecord: true,
    });
    t.after(() => instance.dispose());
    const credential = await callTestCredential(instance);
    const beforeCall = 30 * 86400000 - 360000;
    await instance.advanceClock(beforeCall);
    const joined = await join('waiting', room, instance, credential);
    assert.equal(joined.status, 200);
    const { sessionId, expiresAt } = await joined.json();
    const path = `/api/rooms/${room}/sessions/${sessionId}`;
    assert.equal((await call(`${path}/publish`, {}, 'POST', instance, credential)).status, 200);
    const peer = await prepareReciprocalSubscriptions(instance, 'waiting', path, credential);

    const beforeConfirmation = 310000;
    await instance.advanceClock(beforeConfirmation);
    const first = await confirm(path, credential, 'confirmation-partner', instance);
    assert.equal(first.status, 200);
    const ordinary = await first.json();
    assert.equal(ordinary.sessionId, sessionId);
    assert.ok(ordinary.expiresAt > expiresAt);
    assert.equal(ordinary.establishedAt, undefined);
    assert.equal(ordinary.continuationOnly, undefined);

    await instance.advanceClock(10000);
    const retry = await confirm(path, credential, 'confirmation-partner', instance);
    assert.equal(retry.status, 200);
    assert.equal((await retry.json()).establishedAt, initialTime + beforeCall + beforeConfirmation);

    await instance.advanceClock(40000);
    const continued = await call(`${path}/renew`, {}, 'POST', instance, credential);
    assert.equal(continued.status, 200);
    const lease = await continued.json();
    assert.equal(lease.sessionId, sessionId);
    assert.equal(lease.continuationOnly, true);
    assert.equal((await call(path, undefined, 'DELETE', instance, credential)).status, 200);
    assert.equal((await call(peer.path, undefined, 'DELETE', instance, peer.credential)).status, 200);
});

test('an established call renews only its own lease after the device credential expires', async () => {
    const instance = await makeRuntime({}, { adjustableClock: true });
    try {
        const credential = await callTestCredential(instance);
        await instance.advanceClock(30 * 86400000 - 60000);
        const joined = await join('continues', room, instance, credential);
        assert.equal(joined.status, 200);
        const { sessionId } = await joined.json();
        const base = `/api/rooms/${room}/sessions/${sessionId}`;
        const ordinary = await call(`${base}/renew`, {}, 'POST', instance, credential);
        assert.equal(ordinary.status, 200);
        assert.equal((await ordinary.json()).continuationOnly, undefined);
        assert.equal((await call(`${base}/publish`, {}, 'POST', instance, credential)).status, 200);
        await establishWithPeer(instance, 'continues', base, credential);

        await instance.advanceClock(60000);
        const continuation = await confirm(base, credential, 'confirmation-partner', instance);
        assert.equal(continuation.status, 200);
        const continuedLease = await continuation.json();
        assert.equal(continuedLease.sessionId, sessionId);
        assert.equal(continuedLease.continuationOnly, true);
        assert.equal(continuedLease.establishedAt, undefined);
        assert.equal((await call(`${base}/publish`, {}, 'POST', instance, credential)).status, 401);
        assert.equal((await join('new', room, instance, credential)).status, 401);
        assert.equal((await call(`/api/rooms/${'b'.repeat(64)}/sessions/${sessionId}/renew`,
            {}, 'POST', instance, credential)).status, 401);
        assert.equal((await call(`/api/rooms/${room}/sessions/other/renew`,
            {}, 'POST', instance, credential)).status, 401);
        assert.equal((await call('/api/auth/session', undefined, 'GET', instance, credential)).status, 401);
        assert.equal((await call(base, undefined, 'DELETE', instance, credential)).status, 200);
        assert.equal((await call(`${base}/renew`, {}, 'POST', instance, credential)).status, 404);
        assert.equal((await call('/api/auth/session', undefined, 'DELETE', instance, credential)).status, 200);
        const revoked = await call(`${base}/renew`, {}, 'POST', instance, credential);
        assert.equal(revoked.status, 401);
        assert.equal((await revoked.json()).continuationOnly, undefined);
    } finally { await instance.dispose(); }
});

test('the original call lease crosses a device rotation without extending past 24 hours', async () => {
    const initialTime = Date.now();
    const instance = await makeRuntime(
        {
            LEASE_SECONDS: '3600', MONTHLY_PARTICIPANT_SECONDS: '100000', TURN_ENABLED: 'true',
            CLOUDFLARE_TURN_KEY_ID: 'fixture-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret',
        }, { adjustableClock: true, fixedNowMs: initialTime });
    try {
        const credential = await callTestCredential(instance);
        const iceLeaseID = 'rotation-ice';
        assert.equal((await call(`/api/rooms/${room}/ice/rotation`,
            { leaseID: iceLeaseID }, 'POST', instance, credential)).status, 200);
        const joined = await call(`/api/rooms/${room}/join`,
            { participantId: 'rotation', offer, iceLeaseID }, 'POST', instance, credential);
        assert.equal(joined.status, 200);
        const { sessionId } = await joined.json();
        const base = `/api/rooms/${room}/sessions/${sessionId}`;
        assert.equal((await call(`${base}/publish`, {}, 'POST', instance, credential)).status, 200);
        const establishedAt = await establishWithPeer(instance, 'rotation', base, credential, true);
        const [, accountID, deviceID, secret] = credential.split('.');
        const accounts = await instance.getDurableObjectNamespace('USER_ACCOUNT');
        const account = accounts.get(accounts.idFromString(accountID));
        const replacement = createHash('sha256').update(`${secret}/rotated`).digest('hex');
        const replacementHash = createHash('sha256').update(replacement).digest('hex');
        assert.ok(await account.register(deviceID, replacementHash, Date.now()));
        assert.equal((await call('/api/auth/session', undefined, 'GET', instance, credential)).status, 401);
        assert.equal((await join('before-device-save', room, instance, credential)).status, 401);
        assert.equal((await call(`${base}/pull`, {}, 'POST', instance, credential)).status, 401);
        assert.equal((await call(`${base}/signal`, {}, 'POST', instance, credential)).status, 401);

        let expiresAt;
        let issuedNearDeadline = 0;
        for (let halfHour = 1; halfHour < 48; halfHour++) {
            await instance.advanceClock(1800000);
            const requestsBeforeRenewal = provider.requests.length;
            const renewed = await call(`${base}/renew`, {}, 'POST', instance, credential);
            assert.equal(renewed.status, 200);
            ({ expiresAt } = await renewed.json());
            const remainingSeconds = Math.ceil((establishedAt + 86400000 - initialTime - halfHour * 1800000) / 1000);
            const issued = provider.requests.slice(requestsBeforeRenewal)
                .filter(request => request.url.endsWith('/generate-ice-servers'));
            assert.ok(issued.every(request => request.body.ttl <= remainingSeconds + 1));
            if (halfHour >= 45) issuedNearDeadline += issued.length;
        }
        assert.ok(expiresAt <= establishedAt + 86400000);
        assert.ok(issuedNearDeadline > 0);
        const current = `ri1.${accountID}.${deviceID}.${replacement}`;
        const status = await call('/api/status', undefined, 'GET', instance, current);
        assert.equal(status.status, 200);
        assert.ok((await status.json()).reservedParticipantSeconds <= 86400 + 3600);
        await instance.advanceClock(1800000);
        assert.equal((await call(`${base}/renew`, {}, 'POST', instance, credential)).status, 401);
        assert.equal((await call('/api/auth/session', undefined, 'DELETE', instance, credential)).status, 401);
    } finally { await instance.dispose(); }
});

test('a 30 minute wait does not consume the 24 hours from established call confirmation', async t => {
    const hour = 3600000, halfHour = hour / 2, day = 24 * hour;
    const initialTime = Date.now();
    const instance = await makeRuntime(
        { LEASE_SECONDS: '3600', MONTHLY_PARTICIPANT_SECONDS: '200000' },
        { adjustableClock: true, fixedNowMs: initialTime }
    );
    t.after(() => instance.dispose());
    const firstCredential = await callTestCredential(instance, 'waiting-rider');
    const firstPublishTime = initialTime + 30 * day - hour;
    await instance.advanceClock(firstPublishTime - initialTime);
    const first = await join('waiting-rider', room, instance, firstCredential);
    assert.equal(first.status, 200);
    const firstPath = `/api/rooms/${room}/sessions/${(await first.json()).sessionId}`;
    assert.equal((await call(`${firstPath}/publish`, {}, 'POST', instance, firstCredential)).status, 200);

    await instance.advanceClock(halfHour);
    const peerCredential = await callTestCredential(instance, 'late-rider');
    const peer = await join('late-rider', room, instance, peerCredential);
    assert.equal(peer.status, 200);
    const peerPath = `/api/rooms/${room}/sessions/${(await peer.json()).sessionId}`;
    assert.equal((await call(`${peerPath}/publish`, {}, 'POST', instance, peerCredential)).status, 200);
    assert.equal((await call(`${firstPath}/pull`, { peerIds: ['late-rider'] }, 'POST', instance, firstCredential)).status, 200);
    assert.equal((await call(`${peerPath}/pull`, { peerIds: ['waiting-rider'] }, 'POST', instance, peerCredential)).status, 200);

    const confirmation = await confirm(firstPath, firstCredential, 'late-rider', instance);
    assert.equal(confirmation.status, 200);
    const start = firstPublishTime + halfHour;
    assert.equal((await confirmation.json()).establishedAt, start);

    const renew = (path, credential) => call(`${path}/renew`, {}, 'POST', instance, credential);
    for (let elapsed = halfHour; elapsed < day; elapsed += halfHour) {
        assert.equal((await renew(firstPath, firstCredential)).status, 200);
        assert.equal((await renew(peerPath, peerCredential)).status, 200);
        await instance.advanceClock(halfHour);
    }
    assert.equal((await call('/api/auth/session', undefined, 'GET', instance, firstCredential)).status, 401);
    const lastRenewal = await renew(firstPath, firstCredential);
    assert.equal(lastRenewal.status, 200);
    assert.equal((await lastRenewal.json()).expiresAt, start + day);
    assert.equal((await renew(peerPath, peerCredential)).status, 200);

    await instance.advanceClock(halfHour);
    assert.equal((await renew(firstPath, firstCredential)).status, 401);
    assert.equal((await renew(peerPath, peerCredential)).status, 200);
});

test('only a live pair with reciprocal subscriptions can confirm the first establishment time', async t => {
    const hour = 3600000, halfHour = hour / 2, day = 24 * hour;
    const initialTime = Date.now();
    const instance = await makeRuntime({ LEASE_SECONDS: '3600' }, { adjustableClock: true, fixedNowMs: initialTime });
    t.after(() => instance.dispose());
    const expiredCredential = await callTestCredential(instance, 'establishment-expiring-peer');
    await instance.advanceClock(day);
    const firstCredential = await callTestCredential(instance, 'establishment-owner');
    const peerCredential = await callTestCredential(instance, 'establishment-peer');
    await instance.advanceClock(29 * day - hour);

    const publish = async (id, credential, target = room) => {
        const joined = await join(id, target, instance, credential);
        assert.equal(joined.status, 200);
        const path = `/api/rooms/${target}/sessions/${(await joined.json()).sessionId}`;
        assert.equal((await call(`${path}/publish`, {}, 'POST', instance, credential)).status, 200);
        return path;
    };
    const establishedAt = async (path, credential, peerId) => {
        const response = await confirm(path, credential, peerId, instance);
        assert.equal(response.status, 200);
        return (await response.json()).establishedAt;
    };
    const pull = async (path, credential, peerId) => {
        assert.equal((await call(`${path}/pull`, { peerIds: [peerId] }, 'POST', instance, credential)).status, 200);
    };
    const first = await publish('waiting', firstCredential);
    assert.equal(await establishedAt(first, firstCredential, 'peer'), undefined);
    await instance.advanceClock(halfHour);
    const peer = await publish('peer', peerCredential);
    await pull(first, firstCredential, 'peer');
    assert.equal(await establishedAt(first, firstCredential, 'peer'), undefined);
    await pull(peer, peerCredential, 'waiting');
    assert.equal((await confirm(first, peerCredential, 'peer', instance)).status, 403);
    assert.equal((await confirm(first.replace(room, 'b'.repeat(64)), firstCredential, 'peer', instance)).status, 404);
    assert.equal(await establishedAt(first, firstCredential, 'waiting'), undefined);
    const confirmedAt = initialTime + 30 * day - halfHour;
    const unconfirmedPeer = await publish('not-subscribed', expiredCredential);
    await pull(first, firstCredential, 'not-subscribed');
    assert.equal(await establishedAt(first, firstCredential, 'not-subscribed'), undefined);
    assert.equal(await establishedAt(first, firstCredential, 'not-subscribed,peer'), confirmedAt);
    await pull(unconfirmedPeer, expiredCredential, 'waiting');
    const replacementCredential = await callTestCredential(instance, 'establishment-replacement');
    await instance.advanceClock(halfHour);
    const forgedHeaders = { 'X-Device-Token-Hash': '0'.repeat(64) };
    assert.equal((await confirm(unconfirmedPeer, expiredCredential, 'waiting', instance, forgedHeaders)).status, 401);
    assert.equal(await establishedAt(first, firstCredential, 'peer'), confirmedAt);
    assert.equal((await call(unconfirmedPeer, undefined, 'DELETE', instance, expiredCredential)).status, 401);
    assert.equal((await call(peer, undefined, 'DELETE', instance, peerCredential)).status, 200);
    // The same participant ID now names a different SFU session.
    const replacement = await publish('peer', replacementCredential);
    await pull(replacement, replacementCredential, 'waiting');
    assert.equal(await establishedAt(first, firstCredential, 'peer'), undefined);
    await pull(first, firstCredential, 'peer');
    assert.equal(await establishedAt(first, firstCredential, 'peer'), confirmedAt);
});

test('SFU publishing, authorized subscription, renewal and cleanup use the real contract', async () => {
    const other = await callTestCredential(runtime, 'rider-b');
    const remaining = await callTestCredential(runtime, 'rider-c');
    const a = await (await join('a')).json();
    const b = await (await join('b', room, runtime, other)).json();
    const c = await (await join('c', room, runtime, remaining)).json();
    assert.ok(a.sessionId); assert.equal(a.sessionDescription.type, 'answer');
    assert.ok(a.expiresAt > Date.now()); assert.equal(a.renewAfterSeconds, 300);
    assert.equal('participantToken' in a, false); assert.equal('sfuEndpoint' in a, false);
    const base = `/api/rooms/${room}/sessions/${a.sessionId}`;
    const bPath = `/api/rooms/${room}/sessions/${b.sessionId}`;
    const cPath = `/api/rooms/${room}/sessions/${c.sessionId}`;
    await call(`${base}/publish`, {});
    await call(`${bPath}/publish`, {}, 'POST', runtime, other);
    await call(`${cPath}/publish`, {}, 'POST', runtime, remaining);
    const pull = await (await call(`${base}/pull`, { peerIds: ['b', 'c'] })).json();
    assert.equal(pull.channels[0].peerID, 'b');
    const remainingChannels = pull.channels.filter(channel => channel.peerID === 'c');
    assert.equal(remainingChannels.length, 2);
    const before = provider.requests.length;
    const renewed = await (await call(`${base}/renew`, {})).json();
    assert.equal(renewed.sessionId, a.sessionId); assert.equal(provider.requests.length, before);
    assert.equal((await call(`${base}/pull`, { peerIds: ['not-in-room'] })).status, 403);
    assert.equal((await call(`/api/rooms/${'b'.repeat(64)}/sessions/${a.sessionId}/renew`, {})).status, 404);
    assert.equal((await call(bPath, undefined, 'DELETE', runtime, other)).status, 200);
    const afterDeparture = provider.requests.length;
    const stale = await call(`${base}/pull`, { peerIds: ['b', 'c'] });
    assert.equal(stale.status, 403);
    assert.equal((await stale.json()).code, 'peer_snapshot_changed');
    assert.equal(provider.requests.length, afterDeparture);
    const current = await call(`${base}/pull`, { peerIds: ['c'] });
    assert.equal(current.status, 200);
    assert.deepEqual((await current.json()).channels, remainingChannels);
    assert.equal((await call(base, undefined, 'DELETE')).status, 200);
    assert.equal((await call(cPath, undefined, 'DELETE', runtime, remaining)).status, 200);
    assert.ok(provider.requests.some(r => r.url.endsWith('/datachannels/close')));
});

test('quota reservations survive concurrent provider.requests and prevent provider calls', async () => {
    const limited = await makeRuntime({ MONTHLY_PARTICIPANT_SECONDS: '600' });
    try {
        const results = await Promise.all([join('one', 'c'.repeat(64), limited), join('two', 'd'.repeat(64), limited, await callTestCredential(limited, 'rider-b'))]);
        assert.deepEqual(results.map(r => r.status).sort(), [200, 429]);
        const status = await (await call('/api/status', undefined, 'GET', limited)).json();
        assert.equal(status.reservedParticipantSeconds, 600);
    } finally { await limited.dispose(); }
});

test('join rejects an SFU answer without SDP and a nonnumeric data channel ID', async () => {
    const instance = await makeRuntime();
    try {
        for (const [index, reply] of [
            { sessionDescription: { type: 'answer' }, dataChannel: { id: 0 } },
            { sessionDescription: { type: 'answer', sdp: 'example' }, dataChannel: { id: '0' } },
        ].entries()) {
            provider.establishedChannel = reply;
            const response = await join(`invalid-answer-${index}`, String(index).repeat(64), instance, await callTestCredential(instance, `rider-${index}`));
            assert.equal(response.status, 502);
            assert.deepEqual(await response.json(), { error: 'SFU operation failed' });
        }
    } finally { delete provider.establishedChannel; await instance.dispose(); }
});

test('kill switch fails closed and upstream failure does not publish a participant', async () => {
    const disabled = await makeRuntime({ SERVICE_ENABLED: 'false' });
    try {
        const status = await call('/api/status', undefined, 'GET', disabled);
        const prepare = await call(`/api/rooms/${room}/ice/off`, { leaseID: 'attempt' }, 'POST', disabled);
        const entry = await join('off', room, disabled);
        for (const response of [status, prepare, entry]) {
            assert.equal(response.status, 503);
            assert.equal((await response.json()).code, 'call_service_paused');
        }
    } finally { await disabled.dispose(); }
    provider.upstreamFails = true;
    try { assert.equal((await join('failed', 'e'.repeat(64))).status, 502); } finally { provider.upstreamFails = false; }
});

test('room capacity and duplicate membership are enforced', async () => {
    const small = await makeRuntime({ MAX_ROOM_PARTICIPANTS: '2' });
    try {
        assert.equal((await join('one', room, small)).status, 200);
        assert.equal((await join('one', room, small)).status, 409);
        assert.equal((await join('two', room, small, await callTestCredential(small, 'rider-two'))).status, 200);
        assert.equal((await join('three', room, small, await callTestCredential(small, 'rider-three'))).status, 429);
    } finally { await small.dispose(); }
});


test('ownership and WebSocket sender identity are enforced without exposing provider credentials', async () => {
    const instance = await makeRuntime();
    try {
        const other = await callTestCredential(instance, 'rider-b');
        const owner = await callTestCredential(instance);
        const a = await (await join('alice', room, instance)).json();
        const b = await (await join('bob', room, instance, other)).json();
        const base = `/api/rooms/${room}/sessions/`;
        assert.equal((await call(`${base + a.sessionId}/renew`, {}, 'POST', instance, other)).status, 403);
        const connect = (id, credential) => instance.dispatchFetch(`https://worker.test${base}${id}/signal`, {
            headers: { Authorization: `Bearer ${credential}`, Upgrade: 'websocket' } });
        const ra = await connect(a.sessionId, owner), rb = await connect(b.sessionId, other);
        assert.equal(ra.status, 101); assert.equal(rb.status, 101);
        ra.webSocket.accept(); rb.webSocket.accept();
        const received = new Promise((resolve, reject) => {
            const timeout = setTimeout(() => reject(new Error('message timeout')), 3000);
            rb.webSocket.addEventListener('message', e => {
                const d = JSON.parse(e.data);
                if (d.type === 'appData') { clearTimeout(timeout); resolve(d); }
            });
        });
        ra.webSocket.send(JSON.stringify({ type: 'appData', from: 'forged', namespace: 'test', payload: 'aGVsbG8=' }));
        assert.deepEqual(await received, { type: 'appData', from: 'alice', namespace: 'test', payload: 'aGVsbG8=' });
        ra.webSocket.close(); rb.webSocket.close();
        assert.equal((await call(`${base + a.sessionId}/renew`, {}, 'POST', instance)).status, 200);
    } finally { await instance.dispose(); }
});

test('expired lease alarm closes media and releases the active-session slot', async () => {
    const instance = await makeRuntime({ LEASE_SECONDS: '1' });
    try {
        const a = await (await join('expires', room, instance)).json();
        const deadline = Date.now() + 5000;
        let active = 1;
        while (Date.now() < deadline && active) {
            await new Promise(resolve => setTimeout(resolve, 100));
            active = (await (await call('/api/status', undefined, 'GET', instance)).json()).activeSessions;
        }
        assert.equal(active, 0);
        // Wait for the asynchronous alarm, not merely the usage index pruning.
        while (Date.now() < deadline && !provider.requests.some(r => r.url.includes(`${a.sessionId}/datachannels/close`))) {
            await new Promise(resolve => setTimeout(resolve, 100));
        }
        assert.ok(provider.requests.some(r => r.url.includes(`${a.sessionId}/datachannels/close`)));
    } finally { await instance.dispose(); }
});

test('already expired provider session can be removed without an endless cleanup retry', async () => {
    const a = await (await join('gone', 'f'.repeat(64))).json();
    provider.upstreamGone = true;
    try {
        assert.equal((await call(`/api/rooms/${'f'.repeat(64)}/sessions/${a.sessionId}`, undefined, 'DELETE')).status, 200);
    } finally { provider.upstreamGone = false; }
});

test('repeated peer replacement closes old subscriptions without growing channel allocations', async () => {
    const instance = await makeRuntime();
    try {
        const listener = await (await join('listener', room, instance)).json();
        const speaker = await callTestCredential(instance, 'speaker');
        for (let n = 0; n < 10; n++) {
            const talker = await (await join('talker', room, instance, speaker)).json();
            await call(`/api/rooms/${room}/sessions/${talker.sessionId}/publish`, {}, 'POST', instance, speaker);
            const base = `/api/rooms/${room}/sessions/${listener.sessionId}`;
            const response = await call(`${base}/pull`, { peerIds: ['talker'] }, 'POST', instance);
            assert.equal(response.status, 200);
            const result = await response.json();
            assert.equal(result.channels.length, 2);

            assert.equal((await call(`/api/rooms/${room}/sessions/${talker.sessionId}`, undefined, 'DELETE', instance, speaker)).status, 200);
        }
        const pulls = provider.requests.filter(r => r.url.includes(`/sessions/${listener.sessionId}/datachannels/new`));
        assert.equal(pulls.length, 10);
        assert.equal(provider.requests.filter(r => r.url.includes(`/sessions/${listener.sessionId}/datachannels/close`)).length, 9);
    } finally { await instance.dispose(); }
});
