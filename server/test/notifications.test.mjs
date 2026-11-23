import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomBytes, randomUUID, sign } from 'node:crypto';
import { decodeJwt, generateKeyPair, exportJWK, exportPKCS8, SignJWT } from 'jose';
import { makeRuntime, sealInvitationSubmission } from './support/runtime.mjs';

const apple = await generateKeyPair('RS256');
const applePublic = { ...await exportJWK(apple.publicKey), kid: 'notification-apple-fixture', alg: 'RS256' };
const signing = await generateKeyPair('ES256', { extractable: true });
const groupPath = '/api/notifications/group-invitations';
const options = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: 'fixture-app',
    NOTIFICATIONS_ENABLED: 'true', DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signing.privateKey)),
    APNS_PRIVATE_KEY: await exportPKCS8(signing.privateKey), APNS_KEY_ID: 'fixturekey', APPLE_TEAM_ID: 'fixtureteam',
    APNS_TOPIC: 'fixture-app', APNS_ENVIRONMENT: 'sandbox' };
const call = (r, path, body, token, method = 'POST') => r.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.77', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
async function login(r, subject, deviceID = randomUUID()) {
    const a = await (await call(r, '/api/auth/apple/challenge', { deviceID })).json();
    const identityToken = await new SignJWT({ sub: subject, nonce: a.nonce }).setIssuer('https://appleid.apple.com')
        .setAudience('fixture-app').setIssuedAt().setExpirationTime('5m').setProtectedHeader({ alg: 'RS256', kid: applePublic.kid }).sign(apple.privateKey);
    const response = await call(r, '/api/auth/apple/session', { challengeID: a.challengeID, identityToken });
    assert.equal(response.status, 200); return response.json();
}
const register = (r, user, token = 'ab'.repeat(48)) => call(r, '/api/notifications/device', { token, environment: 'sandbox', topic: 'fixture-app' }, user.accessToken, 'PUT');
async function grant(r, receiver, sender) {
    const response = await call(r, '/api/notifications/grants', { senderUserID: sender.userID }, receiver.accessToken);
    assert.equal(response.status, 200); return response.json();
}
const send = (r, user, capability, requestID = randomUUID()) => call(r, '/api/notifications/calls', { capability, requestID }, user.accessToken);
async function setup(overrides = {}, apns = async () => Response.json({}), runtimeOptions = {}) {
    return makeRuntime({ ...options, ...overrides }, { appleKeys: [applePublic], apns, ...runtimeOptions });
}

test('contact deletion relay requires the pair slot and recipient device even after grants are revoked', async () => {
    let notifications = 0;
    const r = await setup({}, async () => { notifications++; return Response.json({}) });
    try {
        const a = await login(r, 'delete-author'), a2 = await login(r, 'delete-author');
        const b = await login(r, 'delete-recipient'), b2 = await login(r, 'delete-recipient'), c = await login(r, 'delete-outsider');
        const permit = await grant(r, b, a);
        assert.equal((await call(r, `/api/notifications/grants/${permit.grantID}`, undefined, b.accessToken, 'DELETE')).status, 200);
        const key = await generateKeyPair('ES256', { extractable: true });
        const jwk = await exportJWK(key.publicKey);
        const recipientKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url');
        const memberID = 'delete-recipient';
        const identity = await (await call(r, '/api/auth/identity', { memberID, deviceKey: recipientKey }, b.accessToken)).json();
        const slot = '12'.repeat(32), id = randomUUID(), expiresAt = Date.now() + 60_000;
        const packet = Buffer.alloc(64, 7).toString('base64'), receipt = Buffer.alloc(64, 9).toString('base64');
        const path = '/api/contact-deletions';
        async function proof(purpose, values) {
            const fields = [purpose, memberID, recipientKey, identity.certificate, identity.issuerKey, JSON.stringify(values)];
            const parts = [Buffer.from('rideintercom.device-proof.v1\0')];
            for (const field of fields) {
                const bytes = Buffer.from(field), size = Buffer.alloc(4);
                size.writeUInt32BE(bytes.length);
                parts.push(size, bytes);
            }
            const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, Buffer.concat(parts));
            return { publicKey: recipientKey, certificate: identity, signature: Buffer.from(signature).toString('base64url') };
        }
        const message = { slot, id, expiresAt, recipient: b.userID, recipientKey, packet };
        const read = { owner: a.userID, slot, proof: await proof('readContactDeletion', [a.userID, slot]) };
        const ack = { owner: a.userID, slot, id, packet: receipt,
            proof: await proof('acknowledgeContactDeletionRelay', [a.userID, slot, id, receipt]) };
        const state = async (response, expected) => {
            assert.equal(response.status, 200);
            assert.deepEqual(await response.json(), { state: expected });
        };
        await state(await call(r, path, message, a.accessToken, 'PUT'), 'pending');
        await state(await call(r, path, message, a.accessToken, 'PUT'), 'pending');
        assert.equal((await call(r, path, { ...message, packet: receipt }, a.accessToken, 'PUT')).status, 409);
        assert.equal((await call(r, path, message, a2.accessToken, 'PUT')).status, 409);
        assert.equal((await call(r, `${path}/read`, read, b2.accessToken)).status, 404);
        assert.equal((await call(r, `${path}/read`, read, c.accessToken)).status, 404);
        assert.equal((await call(r, `${path}/read`, { ...read, slot: '34'.repeat(32) }, b.accessToken)).status, 404);
        assert.deepEqual(await (await call(r, `${path}/read`, read, b.accessToken)).json(), { deletion: { id, expiresAt, packet } });
        assert.equal((await call(r, `${path}/receipt`, { ...ack, packet }, b.accessToken, 'PUT')).status, 404);
        await state(await call(r, `${path}/receipt`, ack, b.accessToken, 'PUT'), 'received');
        await state(await call(r, `${path}/receipt`, ack, b.accessToken, 'PUT'), 'received');
        const authorRead = { owner: a.userID, slot };
        assert.equal((await call(r, `${path}/read`, authorRead, a2.accessToken)).status, 404);
        assert.deepEqual(await (await call(r, `${path}/read`, authorRead, a.accessToken)).json(), { receipt: { id, expiresAt, packet: receipt } });
        await state(await call(r, path, { slot, id, expiresAt }, a.accessToken, 'DELETE'), 'retired');
        await state(await call(r, path, message, a.accessToken, 'PUT'), 'retired');
        assert.equal((await call(r, `${path}/read`, read, b.accessToken)).status, 404);
        const late = { ...message, slot: 'ab'.repeat(32), id: randomUUID() };
        await state(await call(r, path, { slot: late.slot, id: late.id, expiresAt }, a.accessToken, 'DELETE'), 'retired');
        await state(await call(r, path, late, a.accessToken, 'PUT'), 'retired');
        assert.equal(notifications, 0);
    } finally { await r.dispose(); }
});

test('contact deletion relay bounds retained slots and clears them with account deletion without APNs', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-contact-deletion-'));
    const local = (clockOffsetMs = 0) => setup({ NOTIFICATIONS_ENABLED: 'false', APNS_PRIVATE_KEY: '' },
        async () => { throw new Error('Unexpected notification delivery'); }, { storageDirectory, clockOffsetMs });
    let r = await local();
    try {
        const sender = await login(r, 'bounded-deletion-author');
        const recipient = await login(r, 'bounded-deletion-recipient');
        const key = await generateKeyPair('ES256', { extractable: true });
        const jwk = await exportJWK(key.publicKey);
        const recipientKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url');
        const path = '/api/contact-deletions', expiresAt = Date.now() + 60_000;
        const items = Array.from({ length: 65 }, (_, index) => ({ id: randomUUID(), expiresAt,
            slot: index.toString(16).padStart(64, '0'), recipient: recipient.userID, recipientKey,
            packet: Buffer.alloc(64, 5).toString('base64') }));
        const write = (item, author = sender) => call(r, path, item, author.accessToken, 'PUT');
        assert.equal((await write({ ...items[0], expiresAt: Date.now() - 1 })).status, 400);
        const writes = await Promise.all(items.slice(0, 64).map(item => write(item)));
        assert.deepEqual(new Set(writes.map(response => response.status)), new Set([200]));
        assert.equal((await write(items[64])).status, 429);
        assert.equal((await write(items[0])).status, 200, 'An exact retry does not consume another slot');

        await r.dispose();
        r = await local(61_000);
        const newItem = { ...items[64], expiresAt: Date.now() + 120_000 };
        assert.equal((await write(items[0])).status, 400);
        assert.equal((await write(newItem)).status, 200, 'Expired entries free space after restart');

        assert.equal((await call(r, '/api/auth/account', undefined, sender.accessToken, 'DELETE')).status, 200);
        assert.equal((await write(newItem)).status, 401);
        const replacement = await login(r, 'bounded-deletion-author', sender.deviceID);
        assert.notEqual(replacement.userID, sender.userID);
        assert.equal((await write({ ...newItem, id: randomUUID() }, replacement)).status, 200, 'Account deletion removes the old slot');
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('notifications stay unavailable without configuration and do not disable authentication', async () => {
    const r = await setup({ NOTIFICATIONS_ENABLED: 'false' });
    try {
        const a = await login(r, 'a');
        assert.equal((await register(r, a)).status, 503);
        assert.equal((await call(r, '/api/auth/session', undefined, a.accessToken, 'GET')).status, 200);
    } finally { await r.dispose(); }
});

test('only a recipient capability authorizes a fixed alert; dedupe, read and cancel preserve ownership', async () => {
    const requests = [];
    const r = await setup({}, async request => { requests.push({ url: request.url, headers: Object.fromEntries(request.headers), body: await request.json() }); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'), c = await login(r, 'c');
        assert.equal((await register(r, b)).status, 200);
        const g = await grant(r, b, a);
        assert.equal((await send(r, c, g.capability)).status, 403);
        assert.equal((await send(r, a, b.userID)).status, 403);
        const id = randomUUID();
        const response = await send(r, a, g.capability, id);
        assert.equal(response.status, 200); assert.equal((await response.json()).status, 'accepted');
        assert.equal((await send(r, a, g.capability, id.toUpperCase())).status, 200);
        assert.equal(requests.length, 1);
        assert.equal(requests[0].headers['apns-push-type'], 'alert');
        assert.deepEqual(requests[0].body, {
            aps: { alert: { 'title-loc-key': 'CALL_REQUEST_TITLE', 'loc-key': 'CALL_REQUEST_BODY' },
                sound: 'default', category: 'RIDEINTERCOM_CALL_REQUEST' },
            version: 1, requestID: id, recipientID: b.userID
        });
        assert.ok(!JSON.stringify(requests).includes(g.capability));
        const path = `/api/notifications/calls/${b.userID}/${id}`;
        assert.equal((await call(r, path, undefined, c.accessToken, 'GET')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'GET')).status, 404);
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 200);
        assert.equal((await call(r, path, undefined, c.accessToken, 'DELETE')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 410);
        assert.equal((await send(r, a, g.capability, id.toUpperCase())).status, 200);
        assert.equal(requests.length, 1);
    } finally { await r.dispose(); }
});

test('revocation removes the active grant and old capabilities cannot be recreated by replay', async () => {
    const requests = []; const r = await setup({}, async q => { requests.push(q.url); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b);
        const g = await grant(r, b, a);
        assert.equal((await call(r, `/api/notifications/grants/${g.grantID}`, undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 200, 'other recipient cannot revoke this grant');
        assert.equal((await call(r, `/api/notifications/grants/${g.grantID}`, undefined, b.accessToken, 'DELETE')).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 403);
        const next = await grant(r, b, a); assert.notEqual(next.grantID, g.grantID);
        assert.equal((await send(r, a, g.capability)).status, 403);
        assert.equal(requests.length, 1);
    } finally { await r.dispose(); }
});

test('sign-out and credential replacement remove old destinations; deletion retires old grants', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await call(r, '/api/auth/session', undefined, b.accessToken, 'DELETE');
        assert.equal((await send(r, a, g.capability)).status, 200); assert.equal(count, 0);
        const b2 = await login(r, 'b', b.deviceID); await register(r, b2);
        await login(r, 'b', b.deviceID);
        assert.equal((await send(r, a, g.capability)).status, 200); assert.equal(count, 0);
        const b3 = await login(r, 'b', b.deviceID); await register(r, b3);
        assert.equal((await call(r, '/api/auth/account', undefined, b3.accessToken, 'DELETE')).status, 200);
        const b4 = await login(r, 'b', b.deviceID); await register(r, b4);
        assert.notEqual(b4.userID, b.userID);
        assert.equal((await send(r, a, g.capability)).status, 403); assert.equal(count, 0);
    } finally { await r.dispose(); }
});

test('a delayed 410 cannot remove a newly registered token and token ownership prevents cross-account delivery', async () => {
    let first = true, r, b; const seen = [];
    r = await setup({}, async request => {
        seen.push(request.url);
        if (first) { first = false; assert.equal((await register(r, b, 'cd'.repeat(80))).status, 200); return Response.json({ reason: 'Unregistered', timestamp: Date.now() }, { status: 410 }); }
        return Response.json({});
    });
    try {
        const a = await login(r, 'a'); b = await login(r, 'b'); const c = await login(r, 'c');
        await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability); await send(r, a, g.capability);
        assert.equal(seen.length, 2); assert.ok(seen[1].endsWith('cd'.repeat(80)));
        await register(r, c, 'cd'.repeat(80)); await send(r, a, g.capability);
        assert.equal(seen.length, 2);
    } finally { await r.dispose(); }
});

test('APNs failures remain delivery failures and duplicate requests cannot amplify retries', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({ reason: count === 1 ? 'TooManyRequests' : 'ServiceUnavailable' }, { status: count === 1 ? 429 : 503 }); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        const id = randomUUID(); const first = await send(r, a, g.capability, id);
        assert.equal(first.status, 200); assert.equal((await first.json()).status, 'retry_later');
        await send(r, a, g.capability, id); assert.equal(count, 1);
        const second = await send(r, a, g.capability); assert.equal((await second.json()).status, 'retry_later'); assert.equal(count, 2);
    } finally { await r.dispose(); }
});

test('old routing and token indexes are removed on replacement, sign-out and deletion', async () => {
    const r = await setup();
    try {
        const a = await login(r, 'a'), b = await login(r, 'b');
        const { createHash } = await import('node:crypto');
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const tokenKey = value => `token:${createHash('sha256').update(`sandbox|fixture-app|${value}`).digest('hex')}`;
        const readIndex = async key => {
            return indexes.get(indexes.idFromName(key)).current();
        };
        await register(r, b); assert.ok(await readIndex(tokenKey('ab'.repeat(48))));
        await register(r, b, 'ef'.repeat(41)); assert.equal(await readIndex(tokenKey('ab'.repeat(48))), null);
        await call(r, '/api/auth/session', undefined, b.accessToken, 'DELETE');
        assert.equal(await readIndex(tokenKey('ef'.repeat(41))), null);
        const b2 = await login(r, 'b', b.deviceID); await register(r, b2);
        const g = await grant(r, b2, a); assert.ok(g.capability);
        await call(r, '/api/auth/account', undefined, b2.accessToken, 'DELETE');
        assert.equal(await readIndex(`user:${b.userID}`), null);
        assert.equal(await readIndex(tokenKey('ab'.repeat(48))), null);
    } finally { await r.dispose(); }
});

test('a group alert removes both records for an invalid destination and preserves a new registration', async () => {
    const token = 'ef'.repeat(42);
    let r, recipient, registerDuringPush = false, pushStatus = 410, pushes = 0;
    r = await setup({}, async () => {
        pushes++;
        if (registerDuringPush) assert.equal((await register(r, recipient, token)).status, 200);
        return Response.json({}, { status: pushStatus });
    });
    try {
        const sender = await login(r, 'invalid-alert-sender');
        recipient = await login(r, 'invalid-alert-recipient');
        const { capability } = await (await call(r, `${groupPath}/grants`, { senderUserID: sender.userID }, recipient.accessToken)).json();
        const notify = () => call(r, groupPath, {
            capability, requestID: randomUUID(), expiresAt: Date.now() + 60_000, recipientKey: 'k'.repeat(87),
            envelope: randomBytes(64).toString('base64'),
        }, sender.accessToken);
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const destination = indexes.get(indexes.idFromName(`token:${createHash('sha256').update(`sandbox|fixture-app|${token}`).digest('hex')}`));

        assert.equal((await register(r, recipient, token)).status, 200);
        assert.ok(await destination.current());
        assert.equal((await (await notify()).json()).status, 'queued');
        assert.ok(!await destination.current(), 'An unregistered token must not retain an index binding');
        assert.equal((await (await notify()).json()).status, 'queued');
        assert.equal(pushes, 1);

        assert.equal((await register(r, recipient, token)).status, 200);
        const oldRegistration = (await destination.current()).registrationID;
        registerDuringPush = true;
        assert.equal((await (await notify()).json()).status, 'queued');
        const current = await destination.current();
        assert.ok(current);
        assert.notEqual(current.registrationID, oldRegistration);

        registerDuringPush = false;
        pushStatus = 200;
        assert.equal((await (await notify()).json()).status, 'queued');
        assert.equal(pushes, 3);
    } finally { await r.dispose(); }
});

test('notification registration and issuance have an account-scoped mutation budget', async () => {
    const r = await setup({}, undefined, { fixedNowMs: Date.now() });
    try {
        const a = await login(r, 'a');
        for (let i = 0; i < 60; i++) assert.equal((await register(r, a)).status, 200);
        assert.equal((await register(r, a)).status, 429);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: 'a'.repeat(64) }, a.accessToken)).status, 429);
        assert.equal((await call(r, '/api/notifications/device', undefined, a.accessToken, 'DELETE')).status, 200);
    } finally { await r.dispose(); }
});

test('expiry, dedupe and revoked grants survive a runtime restart, including disabled-delivery cancellation', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-notification-restart-'));
    let count = 0; const apns = async () => { count++; return Response.json({}); };
    let r = await setup({}, apns, { storageDirectory });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        const id = randomUUID(); await send(r, a, g.capability, id);
        await r.dispose(); r = await setup({}, apns, { storageDirectory, clockOffsetMs: 121_000 });
        const path = `/api/notifications/calls/${b.userID}/${id}`;
        assert.equal((await call(r, path, undefined, b.accessToken, 'GET')).status, 410);
        await send(r, a, g.capability, id); assert.equal(count, 1);
        const secondID = randomUUID(); await send(r, a, g.capability, secondID); assert.equal(count, 2);
        await call(r, `/api/notifications/grants/${g.grantID}`, undefined, b.accessToken, 'DELETE');
        await r.dispose(); r = await setup({ NOTIFICATIONS_ENABLED: 'false' }, apns, { storageDirectory, clockOffsetMs: 121_000 });
        assert.equal((await call(r, `/api/notifications/calls/${b.userID}/${secondID}`, undefined, a.accessToken, 'DELETE')).status, 200);
        await r.dispose(); r = await setup({}, apns, { storageDirectory, clockOffsetMs: 122_000 });
        assert.equal((await send(r, a, g.capability)).status, 403); assert.equal(count, 2);
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('concurrent duplicate calls send once and cancellation during delivery cannot become accepted again', async () => {
    let count = 0, entered, release; const ready = new Promise(resolve => { entered = resolve; }); const gate = new Promise(resolve => { release = resolve; });
    const r = await setup({}, async () => { count++; entered(); await gate; return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a); const id = randomUUID();
        const first = send(r, a, g.capability, id); await ready;
        const duplicate = await send(r, a, g.capability, id); assert.equal((await duplicate.json()).status, 'processing');
        assert.equal((await call(r, `/api/notifications/calls/${b.userID}/${id}`, undefined, a.accessToken, 'DELETE')).status, 200);
        release(); assert.equal((await (await first).json()).status, 'cancelled'); assert.equal(count, 1);
    } finally { release(); await r.dispose(); }
});

test('recipient deletion or sender sign-out during first delivery stops all remaining device deliveries', async () => {
    for (const retire of ['recipient', 'sender']) {
        let count = 0, r, a, b;
        r = await setup({}, async () => {
            count++;
            if (count === 1) {
                const response = retire === 'recipient' ? await call(r, '/api/auth/account', undefined, b.accessToken, 'DELETE')
                    : await call(r, '/api/auth/session', undefined, a.accessToken, 'DELETE');
                assert.equal(response.status, 200);
            }
            return Response.json({});
        });
        try {
            a = await login(r, 'a'); b = await login(r, 'b'); const another = await login(r, 'b');
            await register(r, b); await register(r, another, 'de'.repeat(64)); const g = await grant(r, b, a);
            const id = randomUUID(); await send(r, a, g.capability, id); assert.equal(count, 1);
            assert.notEqual((await call(r, `/api/notifications/calls/${b.userID}/${id}`, undefined, another.accessToken, 'GET')).status, 200);
        } finally { await r.dispose(); }
    }
});

test('recipient send limit is persisted, while extra private fields and non-Apple credentials are rejected', async () => {
    let count = 0; const r = await setup({}, async () => { count++; return Response.json({}); }, { fixedNowMs: Date.now() });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        assert.equal((await call(r, '/api/notifications/calls', { capability: g.capability, requestID: randomUUID(), displayName: 'PrivateHumanName' }, a.accessToken)).status, 400);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: a.userID, groupID: randomUUID() }, b.accessToken)).status, 400);
        assert.equal((await call(r, '/api/notifications/device', { token: 'ab'.repeat(32), environment: 'production', topic: 'fixture-app' }, b.accessToken, 'PUT')).status, 400);
        assert.equal((await call(r, '/api/notifications/device', {}, 'test-device-token-with-at-least-32-characters', 'PUT')).status, 401);
        for (let i = 0; i < 20; i++) assert.equal((await send(r, a, g.capability)).status, 200);
        assert.equal((await send(r, a, g.capability)).status, 429); assert.equal(count, 20);
    } finally { await r.dispose(); }
});

test('persistent notification state never stores a capability, private names or group material', async () => {
    const { mkdtemp, readFile, readdir, rm } = await import('node:fs/promises'); const { tmpdir } = await import('node:os'); const { join } = await import('node:path');
    const { createHash } = await import('node:crypto');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-notification-privacy-'));
    const r = await setup({}, undefined, { storageDirectory });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability);
        assert.equal((await call(r, '/api/notifications/grants', { senderUserID: a.userID, displayName: 'PrivateNotificationName', groupSecret: 'PrivateGroupMaterial' }, b.accessToken)).status, 400);
        const files = (await readdir(storageDirectory, { recursive: true })).filter(file => /\.sqlite(?:-wal)?$/.test(file));
        assert.ok(files.length > 0);
        const bytes = Buffer.concat(await Promise.all(files.map(file => readFile(join(storageDirectory, file)))));
        assert.ok(bytes.includes(Buffer.from(createHash('sha256').update(g.grantID).digest('hex'))), 'Inspect the persisted active grant');
        for (const secret of [g.capability, 'PrivateNotificationName', 'PrivateGroupMaterial', a.accessToken, b.accessToken]) assert.ok(!bytes.includes(Buffer.from(secret)));
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


test('APNs provider credentials are reused between requests within their validity window', async () => {
    const tokens = []; const r = await setup({}, async request => { tokens.push(request.headers.get('authorization')); return Response.json({}); });
    try {
        const a = await login(r, 'a'), b = await login(r, 'b'); await register(r, b); const g = await grant(r, b, a);
        await send(r, a, g.capability); await send(r, a, g.capability);
        assert.equal(tokens.length, 2); assert.equal(tokens[0], tokens[1]);
    } finally { await r.dispose(); }
});

test('an older device cannot shorten the current public route, while token ownership follows the latest registration', async () => {
    const r = await setup();
    try {
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const route = indexes.get(indexes.idFromName(`user:${'a'.repeat(64)}`));
        const newerExpiry = Date.now() + 120_000, olderExpiry = Date.now() + 60_000;
        const owner = { accountID: 'account-a', userID: 'a'.repeat(64) };
        await route.bind({ ...owner, expiresAt: newerExpiry });
        await route.bind({ ...owner, expiresAt: olderExpiry });
        assert.equal(await (await route.current()).expiresAt, newerExpiry);
        // The same optimization must never preserve a previous APNs-token owner.
        const token = indexes.get(indexes.idFromName(`token:${'b'.repeat(64)}`));
        await token.bind({ ...owner, deviceID: 'device-a', registrationID: 'first', expiresAt: newerExpiry });
        await token.bind({ accountID: 'account-b', userID: 'b'.repeat(64), deviceID: 'device-b', registrationID: 'second', expiresAt: olderExpiry });
        const current = await token.current();
        assert.equal(await current.expiresAt, olderExpiry);
        assert.equal(await current.accountID, 'account-b');
        assert.equal(await current.registrationID, 'second');
        await route.bind({ accountID: 'account-b', userID: 'b'.repeat(64), expiresAt: olderExpiry });
        assert.equal(await (await route.current()).expiresAt, olderExpiry, 'unrelated public identity must not inherit the expiry');
    } finally { await r.dispose(); }
});

test('unconfigured background deliveries stop before reading a body or using the source budget', async () => {
    for (const seed of [undefined, 'invalid', 'a'.repeat(43)]) {
        const configuration = seed === undefined ? {} : { INVITATION_RELAY_KEY_SEED: seed };
        const r = await setup(configuration, undefined, { apiLimit: 1 });
        try {
            for (const path of [`${groupPath}/background`, `${groupPath}/background-cancellation`,
                '/api/ordinary-group-replies/background-acceptance', '/api/contact-deletions/background-publish']) {
                assert.equal((await call(r, path, {})).status, 503);
            }
        } finally { await r.dispose(); }
    }
});

test('background deliveries share a source limit before reading the request body', async () => {
    const r = await setup({ INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url') }, undefined, { apiLimit: 1 });
    try {
        assert.equal((await call(r, `${groupPath}/background`, {})).status, 400);
        assert.equal((await call(r, `${groupPath}/background-cancellation`, {})).status, 429);
        assert.equal((await call(r, '/api/ordinary-group-replies/background-acceptance', {})).status, 429);
        assert.equal((await call(r, '/api/contact-deletions/background-publish', {})).status, 429);
    } finally { await r.dispose(); }
});

test('a background submission authorizes exactly the signed group invitation with the current device session', async () => {
    let deliveries = 0;
    const now = Date.now();
    const r = await setup({ INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url') },
        async () => { deliveries++; return Response.json({}); }, { fixedNowMs: now });
    try {
        const a = await login(r, 'background-author'), b = await login(r, 'background-recipient');
        assert.equal((await register(r, b)).status, 200);
        const key = await generateKeyPair('ES256', { extractable: true });
        const jwk = await exportJWK(key.publicKey);
        const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url');
        const memberID = 'background-author';
        const issueIdentity = async user => {
            const response = await call(r, '/api/auth/identity', { memberID, deviceKey: publicKey }, user.accessToken);
            assert.equal(response.status, 200);
            return response.json();
        };
        const certificate = await issueIdentity(a);
        const grantResult = await call(r, `${groupPath}/grants`, { senderUserID: a.userID }, b.accessToken);
        assert.equal(grantResult.status, 200);
        const permission = await grantResult.json();
        const body = { capability: permission.capability, requestID: randomUUID(), expiresAt: Date.now() + 60_000,
            recipientKey: 'k'.repeat(87), envelope: Buffer.from('fixture background envelope').toString('base64') };
        const hash = text => createHash('sha256').update(text).digest('hex');
        const packet = async (value, user = a, identity = certificate, origin = 'https://worker.test', purpose = 'submitBackgroundGroupInvitation') => {
            const sessionBinding = hash(hash(user.accessToken.split('.')[3]));
            const submission = Buffer.from(JSON.stringify(value)).toString('base64');
            const payload = JSON.stringify([origin, sessionBinding, submission]);
            const fields = [purpose, memberID, publicKey, identity.certificate, identity.issuerKey, payload];
            const parts = [Buffer.from('rideintercom.device-proof.v1\0')];
            for (const field of fields) {
                const bytes = Buffer.from(field), size = Buffer.alloc(4);
                size.writeUInt32BE(bytes.length);
                parts.push(size, bytes);
            }
            const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, Buffer.concat(parts));
            return { senderUserID: user.userID, deviceID: user.deviceID, sessionBinding, submission,
                proof: { publicKey, certificate: identity, signature: Buffer.from(signature).toString('base64url') } };
        };
        const relay = decodeJwt(certificate.certificate).invitationRelayKey;
        const submit = async value => call(r, `${groupPath}/background`, { sealed: await sealInvitationSubmission(value, relay) });
        const cancel = async value => call(r, `${groupPath}/background-cancellation`, { sealed: await sealInvitationSubmission(value, relay) });
        const cancellation = (invitation, user = a, identity = certificate) => packet(
            { recipientUserID: b.userID, requestID: invitation.requestID, expiresAt: invitation.expiresAt },
            user, identity, 'https://worker.test', 'cancelBackgroundGroupInvitation'
        );
        const original = await packet(body);
        assert.equal((await call(r, `${groupPath}/background`, original)).status, 400,
            'background group delivery requires a sealed body');
        const sealed = await sealInvitationSubmission(original, relay);
        const redirected = await r.dispatchFetch(`https://other.worker.test${groupPath}/background`, {
            method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.77' }, body: JSON.stringify({ sealed })
        });
        assert.equal(redirected.status, 401);
        const changed = data => ({ ...original, submission: Buffer.from(JSON.stringify({ ...body, ...data })).toString('base64') });
        for (const data of [{ requestID: randomUUID() }, { expiresAt: body.expiresAt + 1 }, { recipientKey: 'z'.repeat(87) },
            { envelope: Buffer.from('replaced envelope').toString('base64') }, { capability: (await grant(r, b, a)).capability }]) {
            assert.equal((await submit(changed(data))).status, 401);
        }
        assert.equal((await submit(await packet(body, a, certificate, 'https://second.test'))).status, 401);
        assert.equal((await submit({ ...original, senderUserID: b.userID })).status, 401);
        assert.equal((await call(r, groupPath, original)).status, 401);
        assert.equal(deliveries, 0);
        const first = await submit(original);
        assert.equal(first.status, 200);
        assert.deepEqual(await first.json(), { requestID: body.requestID, expiresAt: body.expiresAt, status: 'queued' });
        for (let repeat = 0; repeat < 60; repeat++) assert.equal((await submit(original)).status, 200);
        assert.equal((await call(r, groupPath, body, a.accessToken)).status, 200);
        assert.equal(deliveries, 1);
        const inbox = await call(r, `${groupPath}?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        assert.equal((await inbox.json()).delivery.requestID, body.requestID);
        const receivedPath = `${groupPath}/${b.userID}/${body.requestID}`;
        const receipt = await call(r, receivedPath, undefined, b.accessToken, 'DELETE');
        assert.deepEqual(await receipt.json(), { status: 'received' });
        const exactCancellation = await cancellation(body);
        assert.equal((await call(r, `${groupPath}/background-cancellation`, exactCancellation)).status, 400);
        assert.equal((await submit(exactCancellation)).status, 401);
        assert.equal((await cancel(original)).status, 401);
        const tampered = { ...exactCancellation, submission: Buffer.from(JSON.stringify({
            recipientUserID: b.userID, requestID: randomUUID(), expiresAt: body.expiresAt
        })).toString('base64') };
        assert.equal((await cancel(tampered)).status, 401);
        assert.equal((await cancel(await cancellation(body, b, await issueIdentity(b)))).status, 404);
        assert.equal((await cancel(await cancellation({ ...body, expiresAt: body.expiresAt + 1 }))).status, 404);
        for (let repeat = 0; repeat < 2; repeat++) {
            const result = await cancel(exactCancellation);
            assert.equal(result.status, 200);
            assert.deepEqual(await result.json(), { requestID: body.requestID, expiresAt: body.expiresAt, status: 'received' });
        }
        const queued = { ...body, requestID: randomUUID(), noticeID: body.requestID };
        assert.equal((await submit(await packet(queued))).status, 200);
        const withdrawal = await cancel(await cancellation(queued));
        assert.equal(withdrawal.status, 200);
        assert.deepEqual(await withdrawal.json(), { requestID: queued.requestID, expiresAt: queued.expiresAt, status: 'cancelled' });
        const racing = { ...queued, requestID: randomUUID() };
        const racingSubmission = await packet(racing), racingCancellation = await cancellation(racing);
        const [racingSend, racingCancel] = await Promise.all([submit(racingSubmission), cancel(racingCancellation)]);
        assert.equal(racingSend.status, 200);
        assert.deepEqual(await racingCancel.json(), { requestID: racing.requestID, expiresAt: racing.expiresAt, status: 'cancelled' });
        assert.equal((await (await submit(racingSubmission)).json()).status, 'cancelled');
        const empty = await call(r, `${groupPath}?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        assert.deepEqual(await empty.json(), { delivery: null });
        const pending = { ...body, requestID: randomUUID() };
        const stale = await packet(pending);
        const renewed = await login(r, 'background-author', a.deviceID);
        assert.equal((await cancel(exactCancellation)).status, 401);
        assert.equal((await submit(stale)).status, 401);
        assert.equal((await submit(await packet(pending, renewed, certificate))).status, 401);
        const renewedCertificate = await issueIdentity(renewed);
        const cancellable = await packet(pending, renewed, renewedCertificate);
        const unsubmitted = await cancel(await cancellation(pending, renewed, renewedCertificate));
        assert.equal(unsubmitted.status, 200);
        assert.deepEqual(await unsubmitted.json(), { requestID: pending.requestID, expiresAt: pending.expiresAt, status: 'cancelled' });
        const cancelled = await submit(cancellable);
        assert.equal(cancelled.status, 200);
        assert.equal((await cancelled.json()).status, 'cancelled');
        const expired = await packet({ ...pending, expiresAt: now - 1 }, renewed, renewedCertificate);
        assert.equal((await submit(expired)).status, 400);
        await call(r, `/api/notifications/grants/${permission.grantID}`, undefined, b.accessToken, 'DELETE');
        assert.equal((await submit(cancellable)).status, 403);
        assert.equal((await call(r, '/api/auth/session', undefined, renewed.accessToken, 'DELETE')).status, 200);
        assert.equal((await submit(cancellable)).status, 401);
        assert.equal(deliveries, 1);
    } finally { await r.dispose(); }
});

test('group invitation delivery requires its own permission and keeps opaque offline mail until receipt', async () => {
    const requests = [], r = await setup({}, async q => { requests.push(await q.json()); return Response.json({}); });
    try {
        const a = await login(r, 'group-a'), b = await login(r, 'group-b'), c = await login(r, 'group-c');
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken);
        assert.equal(issued.status, 200); const g = await issued.json(), ordinary = await grant(r, b, a);
        const body = { capability: g.capability, requestID: randomUUID(), expiresAt: Date.now() + 86400000,
            recipientKey: 'k'.repeat(87), envelope: Buffer.from('synthetic encrypted envelope').toString('base64') };
        const submit = (value = body, user = a) => call(r, '/api/notifications/group-invitations', value, user.accessToken);
        assert.equal((await submit({ ...body, capability: ordinary.capability })).status, 403);
        assert.equal((await send(r, a, g.capability)).status, 403);
        assert.equal((await submit(body, c)).status, 403);
        const first = await submit(); assert.equal(first.status, 200); assert.equal((await first.json()).status, 'queued');
        assert.equal(requests.length, 0);
        const read = user => call(r, `/api/notifications/group-invitations?recipientKey=${body.recipientKey}`, undefined, user.accessToken, 'GET');
        assert.equal((await (await read(c)).json()).delivery, null);
        const delivered = (await (await read(b)).json()).delivery;
        assert.equal(delivered.envelope, body.envelope); assert.equal(delivered.senderUserID, a.userID); assert.equal(delivered.requestID, body.requestID);
        assert.equal((await submit({ ...body, envelope: Buffer.from('changed').toString('base64') })).status, 409);
        const path = `/api/notifications/group-invitations/${b.userID}/${body.requestID}`;
        assert.equal((await call(r, path, undefined, c.accessToken, 'DELETE')).status, 404);
        const acknowledge = async user => {
            const result = await call(r, path, undefined, user.accessToken, 'DELETE');
            assert.equal(result.status, 200);
            assert.deepEqual(await result.json(), { status: 'received' });
        };
        await acknowledge(b);
        await acknowledge(a); // Cancellation after the receipt reports the same terminal state.
        await acknowledge(b);
        assert.equal((await (await read(b)).json()).delivery, null);
        assert.equal((await (await submit()).json()).status, 'received'); assert.equal(requests.length, 0);
    } finally { await r.dispose(); }
});

test('queued group invitations pause with notifications and resume without repeated alerts', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-delivery-pause-'));
    let pushes = 0;
    const start = overrides => setup(overrides, async () => { pushes++; return Response.json({}); }, { storageDirectory });
    let r = await start({});
    try {
        const sender = await login(r, 'paused-sender'), recipient = await login(r, 'paused-recipient');
        assert.equal((await register(r, recipient)).status, 200);
        const callGrant = await grant(r, recipient, sender);
        const callID = randomUUID();
        const issued = await call(r, `${groupPath}/grants`, { senderUserID: sender.userID }, recipient.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const invite = { capability, requestID: randomUUID(), recipientKey: 'k'.repeat(87), expiresAt: Date.now() + 60_000,
            envelope: randomBytes(64).toString('base64') };
        const discarded = { ...invite, requestID: randomUUID() };
        const received = { ...invite, requestID: randomUUID() };
        const path = entry => `${groupPath}/${recipient.userID}/${entry.requestID}`;
        const submit = entry => call(r, groupPath, entry, sender.accessToken);
        const read = () => call(r, `${groupPath}?recipientKey=${invite.recipientKey}`, undefined, recipient.accessToken, 'GET');
        const acknowledge = entry => call(r, path(entry), undefined, recipient.accessToken, 'DELETE');
        for (const entry of [invite, discarded, received]) assert.equal((await submit(entry)).status, 200);
        assert.equal((await acknowledge(received)).status, 200);
        assert.equal(pushes, 3);

        const rejected = [];
        for (const overrides of [{ APNS_PRIVATE_KEY: 'fixture-not-a-pkcs8-key' }, { APNS_PRIVATE_KEY: '' }, { NOTIFICATIONS_ENABLED: 'false' }]) {
            await r.dispose();
            r = await start(overrides);
            const reply = await read();
            assert.equal(reply.status, 503);
            assert.deepEqual(await reply.json(), { error: 'Notifications are unavailable', code: 'notifications_unavailable' });
            assert.equal((await acknowledge(invite)).status, 503);
            assert.equal((await call(r, `${groupPath}/additional-devices?recipientKey=${invite.recipientKey}`,
                undefined, recipient.accessToken, 'GET')).status, 503);
            assert.equal((await call(r, `${path(invite)}/additional-devices`, undefined, sender.accessToken, 'GET')).status, 503);
            const newInvite = { ...invite, requestID: randomUUID() };
            assert.equal((await submit(newInvite)).status, 503);
            rejected.push(newInvite);
            assert.equal((await register(r, recipient)).status, 503);
            assert.equal((await send(r, sender, callGrant.capability, callID)).status, 503);
            assert.equal((await call(r, `${groupPath}/background`, {})).status, 503);
            assert.deepEqual(await (await acknowledge(received)).json(), { status: 'received' });
            const status = await call(r, path(invite), undefined, sender.accessToken, 'GET');
            assert.equal((await status.json()).status, 'queued');
            assert.equal(pushes, 3);
        }
        const cancel = await call(r, `${path(discarded)}?discard=1`, undefined, recipient.accessToken, 'DELETE');
        assert.equal(cancel.status, 200);
        assert.deepEqual(await cancel.json(), { status: 'cancelled' });

        await r.dispose();
        r = await start({});
        for (const entry of rejected) assert.equal((await call(r, path(entry), undefined, sender.accessToken, 'GET')).status, 404);
        assert.equal((await call(r, `/api/notifications/calls/${recipient.userID}/${callID}`, undefined, recipient.accessToken, 'GET')).status, 404);
        assert.equal((await (await read()).json()).delivery.requestID, invite.requestID);
        assert.deepEqual(await (await acknowledge(invite)).json(), { status: 'received' });
        assert.equal((await (await read()).json()).delivery, null);
        assert.equal(pushes, 3);
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('a cancellation after download is reported to a delayed or repeated acknowledgement', async () => {
    const r = await setup();
    try {
        const sender = await login(r, 'downloaded-invite-sender'), recipient = await login(r, 'downloaded-invite-recipient');
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: sender.userID }, recipient.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const requestID = randomUUID(), recipientKey = 'k'.repeat(87);
        const invitation = { capability, requestID, recipientKey, expiresAt: Date.now() + 86400000,
            envelope: Buffer.from('opaque invitation').toString('base64') };
        const post = () => call(r, '/api/notifications/group-invitations', invitation, sender.accessToken);
        const initial = await post();
        assert.equal(initial.status, 200);
        assert.equal((await initial.json()).status, 'queued');
        const read = () => call(r, `/api/notifications/group-invitations?recipientKey=${recipientKey}`, undefined, recipient.accessToken, 'GET');
        const downloaded = await read();
        assert.equal(downloaded.status, 200);
        assert.equal((await downloaded.json()).delivery.requestID, requestID);

        const path = `/api/notifications/group-invitations/${recipient.userID}/${requestID}`;
        for (const actor of [sender, recipient, recipient]) {
            const result = await call(r, path, undefined, actor.accessToken, 'DELETE');
            assert.equal(result.status, 200);
            assert.deepEqual(await result.json(), { status: 'cancelled' });
        }
        assert.deepEqual(await (await read()).json(), { delivery: null });
        assert.equal((await (await post()).json()).status, 'cancelled');
    } finally { await r.dispose(); }
});

test('group invitation acknowledgement uses the current grant and preserves earlier receipts', async () => {
    const r = await setup();
    try {
        const sender = await login(r, 'revoke-invitation-sender');
        const recipient = await login(r, 'revoke-invitation-recipient');
        const issued = await call(r, `${groupPath}/grants`, { senderUserID: sender.userID }, recipient.accessToken);
        assert.equal(issued.status, 200);
        const { capability, grantID } = await issued.json();

        const download = async recipientKey => {
            const id = randomUUID();
            const response = await call(r, groupPath, {
                capability, requestID: id, recipientKey, expiresAt: Date.now() + 60_000,
                envelope: Buffer.from('synthetic invitation ciphertext').toString('base64'),
            }, sender.accessToken);
            assert.equal(response.status, 200);
            assert.equal((await response.json()).status, 'queued');
            const inbox = await call(r, `${groupPath}?recipientKey=${recipientKey}`, undefined, recipient.accessToken, 'GET');
            assert.equal((await inbox.json()).delivery?.requestID, id);
            return `${groupPath}/${recipient.userID}/${id}`;
        };
        const ack = async path => {
            const response = await call(r, path, undefined, recipient.accessToken, 'DELETE');
            assert.equal(response.status, 200);
            return response.json();
        };
        const accepted = await download('a'.repeat(87));
        assert.deepEqual(await ack(accepted), { status: 'received' });
        const pending = await download('b'.repeat(87));
        const revoked = await call(r, `/api/notifications/grants/${grantID}`, undefined, recipient.accessToken, 'DELETE');
        assert.equal(revoked.status, 200);

        assert.deepEqual(await ack(pending), { status: 'cancelled' });
        assert.deepEqual(await ack(pending), { status: 'cancelled' });
        assert.deepEqual(await ack(accepted), { status: 'received' });
        const senderStatus = await call(r, pending, undefined, sender.accessToken, 'GET');
        assert.equal(senderStatus.status, 200);
        assert.equal((await senderStatus.json()).status, 'cancelled');
    } finally { await r.dispose(); }
});

test('group invitation alerts hide ciphertext and cancellation and grant revocation block later receipt', async () => {
    const requests = [], r = await setup({}, async q => { requests.push(await q.json()); return Response.json({}); });
    try {
        const a = await login(r, 'invite-a'), b = await login(r, 'invite-b'); await register(r, b);
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken);
        assert.equal(issued.status, 200); const g = await issued.json();
        const body = { capability: g.capability, requestID: randomUUID(), noticeID: randomUUID(), expiresAt: Date.now() + 86400000,
            recipientKey: 'p'.repeat(87), envelope: Buffer.from('opaque group ciphertext').toString('base64') };
        const submit = (value = body) => call(r, '/api/notifications/group-invitations', value, a.accessToken);
        assert.equal((await submit()).status, 200); assert.equal(requests.length, 1);
        assert.deepEqual(requests[0].aps, {
            alert: { 'title-loc-key': 'GROUP_INVITATION_TITLE', 'loc-key': 'GROUP_INVITATION_BODY' },
            category: 'RIDEINTERCOM_GROUP_INVITATION',
            'interruption-level': 'passive',
        });
        assert.equal(requests[0].kind, 'groupInvitation');
        assert.ok(!JSON.stringify(requests).includes(body.envelope));
        assert.equal((await submit()).status, 200); assert.equal(requests.length, 1);
        const path = `/api/notifications/group-invitations/${b.userID}/${body.requestID}`;
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await (await call(r, path, undefined, a.accessToken, 'GET')).json()).status, 'cancelled');
        assert.equal((await (await submit()).json()).status, 'cancelled');
        assert.equal((await submit({ ...body, requestID: randomUUID(), recipientKey: 'q'.repeat(87) })).status, 200);
        assert.equal(requests.length, 1, 'Known recipient devices share one notification batch');
        await call(r, `/api/notifications/grants/${g.grantID}`, undefined, b.accessToken, 'DELETE');
        const read = await call(r, `/api/notifications/group-invitations?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        assert.equal((await read.json()).delivery, null);
        assert.equal((await submit({ ...body, expiresAt: Date.now() + 8 * 86400000 })).status, 400);
    } finally { await r.dispose(); }
});

test('concurrent device deliveries for one invitation send one alert to each registered device', { timeout: 10_000 }, async () => {
    const savedBoth = Promise.withResolvers();
    let saved = 0;
    const pushes = [];
    const r = await setup({}, async request => {
        pushes.push({ destination: new URL(request.url).pathname, payload: await request.json() });
        return Response.json({});
    }, {
        onInvitationStore: async phase => {
            if (phase !== 'after') return;
            if (++saved === 2) savedBoth.resolve();
            // Both packets must be committed before either request sends the alert.
            await savedBoth.promise;
        },
    });
    try {
        const sender = await login(r, 'concurrent-invite-sender');
        const recipient = await login(r, 'concurrent-invite-recipient');
        const secondDevice = await login(r, 'concurrent-invite-recipient');
        assert.equal((await register(r, recipient)).status, 200);
        assert.equal((await register(r, secondDevice, 'cd'.repeat(48))).status, 200);
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: sender.userID }, recipient.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const noticeID = randomUUID(), expiresAt = Date.now() + 86400000;
        const invitations = ['p', 'q'].map(key => ({
            capability, noticeID, expiresAt, requestID: randomUUID(), recipientKey: key.repeat(87),
            envelope: Buffer.from(`opaque packet ${key}`).toString('base64'),
        }));
        const submit = payload => call(r, '/api/notifications/group-invitations', payload, sender.accessToken);
        const responses = await Promise.all(invitations.map(submit));
        for (const response of responses) {
            assert.equal(response.status, 200);
            assert.equal((await response.json()).status, 'queued');
        }
        for (const [index, device] of [recipient, secondDevice].entries()) {
            const invitation = invitations[index];
            const inbox = await call(r, `/api/notifications/group-invitations?recipientKey=${invitation.recipientKey}`,
                undefined, device.accessToken, 'GET');
            assert.equal((await inbox.json()).delivery.requestID, invitation.requestID);
        }
        assert.equal(pushes.length, 2);
        assert.equal(new Set(pushes.map(push => push.destination)).size, 2);
        assert.equal(new Set(pushes.map(push => push.payload.requestID)).size, 1);
        await Promise.all(invitations.map(submit));
        assert.equal(pushes.length, 2);
    } finally { savedBoth.resolve(); await r.dispose(); }
});

test('an inbox read in flight skips a cancelled candidate and delivers the next invitation', { timeout: 10_000 }, async () => {
    const snapshot = Promise.withResolvers(), release = Promise.withResolvers();
    const r = await setup({}, undefined, { afterInboxSnapshot: async () => {
        snapshot.resolve();
        await release.promise;
    } });
    try {
        const a = await login(r, 'cancelling-sender'), b = await login(r, 'reading-recipient');
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const recipientKey = 'k'.repeat(87), expiresAt = Date.now() + 86400000;
        const cancelled = { requestID: '00000000-0000-4000-8000-000000000001', envelope: Buffer.from('cancelled').toString('base64') };
        const unaffected = { requestID: '00000000-0000-4000-8000-000000000002', envelope: Buffer.from('unaffected').toString('base64') };
        for (const invitation of [cancelled, unaffected]) {
            const submit = await call(r, '/api/notifications/group-invitations', { capability, recipientKey, expiresAt, ...invitation }, a.accessToken);
            assert.equal((await submit.json()).status, 'queued');
        }
        const inbox = `/api/notifications/group-invitations?recipientKey=${recipientKey}`;
        const read = () => call(r, inbox, undefined, b.accessToken, 'GET');
        const inFlight = read();
        await Promise.race([snapshot.promise, inFlight.then(() => assert.fail('The inbox read finished before the candidate snapshot'))]);
        const path = `/api/notifications/group-invitations/${b.userID}/${cancelled.requestID}`;
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 200);
        release.resolve();
        const response = await inFlight;
        assert.equal(response.status, 200);
        assert.deepEqual((await response.json()).delivery, { ...unaffected, recipientKey, expiresAt, senderUserID: a.userID });
        const receiptPath = `/api/notifications/group-invitations/${b.userID}/${unaffected.requestID}`;
        assert.equal((await call(r, receiptPath, undefined, b.accessToken, 'DELETE')).status, 200);
        assert.deepEqual(await (await read()).json(), { delivery: null });
    } finally { release.resolve(); await r.dispose(); }
});

test('cancellation before the first mailbox write prevents delayed delivery', { timeout: 10_000 }, async () => {
    const store = Promise.withResolvers(), release = Promise.withResolvers();
    const stored = Promise.withResolvers(), respond = Promise.withResolvers();
    let notifications = 0;
    const r = await setup({}, async () => { notifications++; return Response.json({}); }, {
        onInvitationStore: async phase => {
            if (phase === 'before') { store.resolve(); await release.promise; }
            else { stored.resolve(); await respond.promise; }
        }
    });
    try {
        const a = await login(r, 'delayed-sender'), b = await login(r, 'delayed-recipient'), c = await login(r, 'other-sender');
        assert.equal((await register(r, b)).status, 200);
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const body = { capability, requestID: randomUUID(), expiresAt: Date.now() + 86400000,
            recipientKey: 'p'.repeat(87), envelope: Buffer.from('delayed').toString('base64') };
        const submit = (invitation = body) => call(r, '/api/notifications/group-invitations', invitation, a.accessToken);
        const cancel = (user, id) => call(r, `/api/notifications/group-invitations/${b.userID}/${id}`, undefined, user.accessToken, 'DELETE');
        const read = () => call(r, `/api/notifications/group-invitations?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        const pending = submit();
        await Promise.race([store.promise, pending.then(() => assert.fail('The invitation was not held before storage'))]);
        const cancelled = await cancel(a, body.requestID);
        release.resolve();
        await Promise.race([stored.promise, pending.then(() => assert.fail('The invitation was not held after storage'))]);
        assert.deepEqual(await (await read()).json(), { delivery: null });
        respond.resolve();
        const delivered = await pending;
        assert.equal(cancelled.status, 404);
        assert.equal(delivered.status, 200);
        assert.equal((await delivered.json()).status, 'cancelled');
        assert.equal((await (await submit()).json()).status, 'cancelled');
        assert.equal(notifications, 0);

        const unrelated = { ...body, requestID: randomUUID() };
        assert.equal((await cancel(c, unrelated.requestID)).status, 404);
        assert.equal((await (await submit(unrelated)).json()).status, 'queued');
        assert.equal((await (await read()).json()).delivery.requestID, unrelated.requestID);
        assert.equal(notifications, 1);
    } finally { release.resolve(); respond.resolve(); await r.dispose(); }
});

test('an early group cancellation survives restart and credential rotation', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-cancellation-'));
    let r = await setup({}, undefined, { storageDirectory });
    try {
        const a = await login(r, 'persist-canceller'), b = await login(r, 'persist-recipient');
        const issued = await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken);
        assert.equal(issued.status, 200);
        const { capability } = await issued.json();
        const body = { capability, requestID: randomUUID(), expiresAt: Date.now() + 86400000,
            recipientKey: 'q'.repeat(87), envelope: Buffer.from('stale delivery').toString('base64') };
        const path = `/api/notifications/group-invitations/${b.userID}/${body.requestID}`;
        assert.equal((await call(r, path, undefined, b.accessToken, 'DELETE')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 404);
        assert.equal((await call(r, path, undefined, a.accessToken, 'DELETE')).status, 404);
        await r.dispose();
        r = await setup({}, undefined, { storageDirectory });
        const current = await login(r, 'persist-canceller', a.deviceID);
        assert.equal((await call(r, '/api/notifications/group-invitations', body, a.accessToken)).status, 401);
        const delayed = await call(r, '/api/notifications/group-invitations', body, current.accessToken);
        assert.equal(delayed.status, 200);
        assert.equal((await delayed.json()).status, 'cancelled');
        const inbox = await call(r, `/api/notifications/group-invitations?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        assert.deepEqual(await inbox.json(), { delivery: null });
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('early group cancellations are bounded per sender and expire', { timeout: 15_000 }, async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-cancellation-limit-'));
    const now = Date.now();
    let r = await setup({}, undefined, { storageDirectory, fixedNowMs: now });
    try {
        const a = await login(r, 'full-canceller'), b = await login(r, 'independent-canceller');
        const recipient = 'd'.repeat(64);
        const cancel = (user, id) => call(r, `/api/notifications/group-invitations/${recipient}/${id}`, undefined, user.accessToken, 'DELETE');
        const ids = Array.from({ length: 512 }, () => randomUUID());
        for (let start = 0; start < ids.length; start += 16) {
            const writes = await Promise.all(ids.slice(start, start + 16).map(id => cancel(a, id)));
            assert.ok(writes.every(reply => reply.status === 404));
        }
        assert.equal((await cancel(a, ids[0])).status, 404, 'Repeating a cancellation consumes no slot');
        assert.equal((await cancel(a, randomUUID())).status, 429);
        assert.equal((await cancel(b, randomUUID())).status, 404, 'The limit is local to the sender');
        await r.dispose();
        r = await setup({}, undefined, { storageDirectory, fixedNowMs: now + 8 * 86400000 });
        assert.equal((await cancel(a, randomUUID())).status, 429, 'The cancel-before-storage records survive the invitation window');
        await r.dispose();
        r = await setup({}, undefined, { storageDirectory, fixedNowMs: now + 28 * 86400000 });
        assert.equal((await cancel(a, randomUUID())).status, 404, 'Expired cancellations release their slots');
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('group invitation receipt requires a current resubmission after sender sign-in', async () => {
    const r = await setup();
    try {
        const a = await login(r, 'resume-a'), b = await login(r, 'resume-b');
        const g = await (await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken)).json();
        const body = { capability: g.capability, requestID: randomUUID(), expiresAt: Date.now() + 86400000,
            recipientKey: 'r'.repeat(87), envelope: Buffer.from('opaque pending packet').toString('base64') };
        const submit = (user, value = body) => call(r, '/api/notifications/group-invitations', value, user.accessToken);
        const read = () => call(r, `/api/notifications/group-invitations?recipientKey=${body.recipientKey}`, undefined, b.accessToken, 'GET');
        assert.equal((await submit(a)).status, 200);
        await call(r, '/api/auth/session', undefined, a.accessToken, 'DELETE');
        assert.equal((await (await read()).json()).delivery, null);
        assert.equal((await submit(a)).status, 401);
        const current = await login(r, 'resume-a', a.deviceID);
        assert.equal((await submit(current)).status, 200);
        assert.equal((await (await read()).json()).delivery.envelope, body.envelope);
        assert.equal((await submit(current, { ...body, envelope: 'a'.repeat(22000) })).status, 400);
        assert.equal((await submit(current, { ...body, recipientKey: '../other' })).status, 400);
        const path = `/api/notifications/group-invitations/${b.userID}/${body.requestID}`;
        assert.equal((await call(r, `${path}?discard=1`, undefined, b.accessToken, 'DELETE')).status, 200);
        assert.equal((await (await call(r, path, undefined, current.accessToken, 'GET')).json()).status, 'cancelled');
    } finally { await r.dispose(); }
});

test('a downloaded group invitation waits for the sender to resubmit after sign-out', async () => {
    const r = await setup();
    try {
        const sender = await login(r, 'acknowledgement-sender');
        const recipient = await login(r, 'acknowledgement-recipient');
        const grant = await call(r, `${groupPath}/grants`, { senderUserID: sender.userID }, recipient.accessToken);
        assert.equal(grant.status, 200);
        const { capability } = await grant.json();
        const requestID = randomUUID(), recipientKey = 'k'.repeat(87);
        const body = { capability, requestID, recipientKey, expiresAt: Date.now() + 60_000,
            envelope: Buffer.from('synthetic invitation ciphertext').toString('base64') };
        const path = `${groupPath}/${recipient.userID}/${requestID}`;
        const submit = user => call(r, groupPath, body, user.accessToken);
        const ack = () => call(r, path, undefined, recipient.accessToken, 'DELETE');
        const signOut = user => call(r, '/api/auth/session', undefined, user.accessToken, 'DELETE');
        assert.equal((await submit(sender)).status, 200);
        const download = await call(r, `${groupPath}?recipientKey=${recipientKey}`, undefined, recipient.accessToken, 'GET');
        assert.equal((await download.json()).delivery?.requestID, requestID);
        assert.equal((await signOut(sender)).status, 200);
        assert.equal((await ack()).status, 409);
        const queued = await call(r, path, undefined, recipient.accessToken, 'GET');
        assert.deepEqual(await queued.json(), { requestID, expiresAt: body.expiresAt, status: 'queued' });

        const current = await login(r, 'acknowledgement-sender', sender.deviceID);
        assert.equal((await ack()).status, 409, 'Signing in alone cannot reactivate the old invitation');
        assert.equal((await submit(current)).status, 200);
        const received = await ack();
        assert.equal(received.status, 200);
        assert.deepEqual(await received.json(), { status: 'received' });
        assert.equal((await signOut(current)).status, 200);
        assert.deepEqual(await (await ack()).json(), { status: 'received' });
    } finally { await r.dispose(); }
});

test('group invitation lifetime tolerates a small device clock difference but stays bounded', async () => {
    const r = await setup();
    try {
        const a = await login(r, 'clock-a'), b = await login(r, 'clock-b');
        const g = await (await call(r, '/api/notifications/group-invitations/grants', { senderUserID: a.userID }, b.accessToken)).json();
        const body = { capability: g.capability, requestID: randomUUID(), expiresAt: Date.now() + 7 * 86400000 + 60000,
            recipientKey: 's'.repeat(87), envelope: Buffer.from('opaque clock fixture').toString('base64') };
        assert.equal((await call(r, '/api/notifications/group-invitations', body, a.accessToken)).status, 200);
        assert.equal((await call(r, '/api/notifications/group-invitations', { ...body, requestID: randomUUID(), expiresAt: Date.now() + 7 * 86400000 + 600000 }, a.accessToken)).status, 400);
    } finally { await r.dispose(); }
});

test('group invitation outcomes survive the invite deadline for up to 28 days from storage', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises');
    const { tmpdir } = await import('node:os');
    const { join } = await import('node:path');
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-outcome-retention-'));
    const day = 86_400_000, now = Date.now();
    const at = fixedNowMs => setup({}, undefined, { storageDirectory, fixedNowMs });
    let r = await at(now);
    try {
        const sender = await login(r, 'retained-outcome-sender');
        const receiver = await login(r, 'retained-outcome-receiver');
        const other = await login(r, 'retained-outcome-unrelated');
        const path = '/api/notifications/group-invitations';
        const grant = await call(r, `${path}/grants`, { senderUserID: sender.userID }, receiver.accessToken);
        assert.equal(grant.status, 200);
        const { capability } = await grant.json();
        const expiresAt = now + 7 * day;
        const make = key => ({ requestID: randomUUID(), capability, expiresAt,
            recipientKey: key.repeat(87), envelope: Buffer.from('opaque invitation').toString('base64') });
        const received = make('r'), cancelled = make('c'), pending = make('p');
        const item = id => `${path}/${receiver.userID}/${id}`;
        const lookup = (request, user = sender) => call(r, item(request.requestID), undefined, user.accessToken, 'GET');
        const finish = (request, user) => call(r, item(request.requestID), undefined, user.accessToken, 'DELETE');
        for (const request of [received, cancelled, pending]) {
            assert.equal((await call(r, path, request, sender.accessToken)).status, 200);
        }
        assert.deepEqual(await (await finish(received, receiver)).json(), { status: 'received' });
        assert.deepEqual(await (await finish(cancelled, sender)).json(), { status: 'cancelled' });

        await r.dispose(); r = await at(now + 8 * day);
        for (const [request, status] of [[received, 'received'], [cancelled, 'cancelled']]) {
            const response = await lookup(request);
            assert.equal(response.status, 200);
            assert.deepEqual(await response.json(), { requestID: request.requestID, expiresAt, status });
            assert.deepEqual(await (await finish(request, receiver)).json(), { status });
            assert.equal((await lookup(request, other)).status, 404);
        }
        assert.equal((await lookup(pending)).status, 404);
        assert.equal((await finish(pending, receiver)).status, 404);
        const inbox = await call(r, `${path}?recipientKey=${pending.recipientKey}`, undefined, receiver.accessToken, 'GET');
        assert.deepEqual(await inbox.json(), { delivery: null });
        const additional = await call(r, `${item(received.requestID)}/additional-devices`, undefined, sender.accessToken, 'GET');
        assert.equal(additional.status, 404);
        assert.equal((await call(r, path, received, sender.accessToken)).status, 400);
        const fresh = { ...received, expiresAt: now + 9 * day };
        assert.equal((await call(r, path, fresh, sender.accessToken)).status, 409);
        assert.equal((await call(r, path, { ...fresh, requestID: randomUUID() }, sender.accessToken)).status, 200);

        await r.dispose(); r = await at(now + 28 * day - 1);
        assert.equal((await lookup(received)).status, 200);
        assert.equal((await lookup(cancelled)).status, 200);
        await r.dispose(); r = await at(now + 28 * day);
        assert.equal((await lookup(received)).status, 404);
        assert.equal((await lookup(cancelled)).status, 404);
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('the original sender can read a certified additional device for a live group invitation', async () => {
    const r = await setup();
    try {
        const sender = await login(r, 'additional-device-sender');
        const otherSenderDevice = await login(r, 'additional-device-sender');
        const recipient = await login(r, 'additional-device-recipient');
        const additional = await login(r, 'additional-device-recipient');
        const outsider = await login(r, 'additional-device-outsider');
        const requestID = randomUUID(), expiresAt = Date.now() + 86_400_000;
        const invite = '/api/notifications/group-invitations';
        const groupGrant = await (await call(r, `${invite}/grants`, { senderUserID: sender.userID }, recipient.accessToken)).json();
        const submission = { capability: groupGrant.capability, requestID, expiresAt, recipientKey: 'r'.repeat(87),
            envelope: Buffer.from('opaque group packet').toString('base64') };
        assert.equal((await call(r, invite, submission, sender.accessToken)).status, 200);
        // An existing recipient's receipt leaves the invitation active for new devices until its original expiry.
        const original = `${invite}/${recipient.userID}/${requestID}`;
        assert.equal((await (await call(r, original, undefined, recipient.accessToken, 'DELETE')).json()).status, 'received');

        const key = await generateKeyPair('ES256', { extractable: true });
        const jwk = await exportJWK(key.publicKey);
        const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url');
        const memberID = 'additional-member';
        const identityResponse = await call(r, '/api/auth/identity', { memberID, deviceKey: publicKey }, additional.accessToken);
        assert.equal(identityResponse.status, 200);
        const certificate = await identityResponse.json();
        function makeProof(id, purpose = 'requestGroupInvitationRedelivery', signingKey = key.privateKey, identity = certificate) {
            const fields = [purpose, memberID, publicKey, identity.certificate, identity.issuerKey, id];
            const parts = [Buffer.from('rideintercom.device-proof.v1\0')];
            for (const field of fields) {
                const bytes = Buffer.from(field), length = Buffer.alloc(4);
                length.writeUInt32BE(bytes.length);
                parts.push(length, bytes);
            }
            const signature = sign('sha256', Buffer.concat(parts), { key: signingKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
            return { publicKey, certificate: identity, signature };
        }
        const path = `${original}/additional-devices`;
        const discover = (by = additional) => call(r, `${invite}/additional-devices?recipientKey=${publicKey}`,
            undefined, by.accessToken, 'GET');
        const read = (by = sender, at = path) => call(r, at, undefined, by.accessToken, 'GET');
        const submit = (proof, by = additional, at = path) => call(r, at, proof, by.accessToken);
        const proof = makeProof(requestID);
        assert.deepEqual(await (await read()).json(), { devices: [] });
        assert.equal((await submit(proof, outsider)).status, 404);
        assert.equal((await submit(proof, recipient)).status, 403, 'The certificate must match the authenticated device');
        const wrongKey = await generateKeyPair('ES256');
        assert.equal((await submit(makeProof(requestID, undefined, wrongKey.privateKey))).status, 403);
        assert.equal((await submit(makeProof(requestID, 'callNotificationPermission'))).status, 403);
        const makeCertificate = (signingKey, expiresIn) => new SignJWT({ memberID, deviceKey: publicKey, deviceID: additional.deviceID })
            .setIssuer('https://worker.test').setSubject(additional.userID).setAudience('rideintercom-peer')
            .setIssuedAt(Math.floor(Date.now() / 1000) - 1800).setExpirationTime(expiresIn)
            .setProtectedHeader({ alg: 'ES256', typ: 'rideintercom-device+jwt' }).sign(signingKey);
        const expired = { ...certificate, certificate: await makeCertificate(signing.privateKey, '-1m') };
        const forged = { ...certificate, certificate: await makeCertificate(wrongKey.privateKey, '5m') };
        assert.equal((await submit(makeProof(requestID, undefined, undefined, expired))).status, 403);
        assert.equal((await submit(makeProof(requestID, undefined, undefined, forged))).status, 403);
        assert.equal((await submit(proof, additional, `${invite}/${recipient.userID}/${randomUUID()}/additional-devices`)).status, 404);
        const secondID = randomUUID();
        assert.equal((await call(r, invite, { ...submission, requestID: secondID }, sender.accessToken)).status, 200);
        const otherPath = `${invite}/${recipient.userID}/${secondID}/additional-devices`;
        assert.equal((await submit(proof, additional, otherPath)).status, 403, 'The signature cannot authorize another invitation');

        assert.equal((await submit(proof)).status, 200);
        assert.equal((await submit(proof)).status, 200, 'Retry stays idempotent');
        assert.deepEqual(await (await discover()).json(), { requestIDs: [secondID] });
        const addresses = { devices: [{ memberID, recipientKey: publicKey }] };
        assert.deepEqual(await (await read()).json(), addresses);
        assert.equal((await read(otherSenderDevice)).status, 404);
        assert.equal((await read(outsider)).status, 404);
        assert.equal((await read(recipient)).status, 404);
        const redelivery = { ...submission, requestID: randomUUID(), noticeID: requestID, sourceRequestID: requestID,
            recipientKey: publicKey, envelope: Buffer.from('opaque packet reencrypted for the additional device').toString('base64') };
        const sendAgain = (body = redelivery, by = sender) => call(r, invite, body, by.accessToken);
        assert.equal((await sendAgain({ ...redelivery, recipientKey: submission.recipientKey })).status, 403);
        assert.equal((await sendAgain({ ...redelivery, expiresAt: expiresAt + 1 })).status, 403);
        assert.equal((await sendAgain({ ...redelivery, noticeID: randomUUID() })).status, 403);
        assert.equal((await sendAgain({ ...redelivery, sourceRequestID: secondID })).status, 403);
        assert.equal((await sendAgain(redelivery, otherSenderDevice)).status, 403);
        assert.equal((await sendAgain()).status, 200);
        const addressedInbox = user => call(r, `${invite}?recipientKey=${publicKey}`, undefined, user.accessToken, 'GET');
        assert.equal((await (await addressedInbox(recipient)).json()).delivery, null);
        const delivered = (await (await addressedInbox(additional)).json()).delivery;
        assert.equal(delivered.requestID, redelivery.requestID);
        assert.equal(delivered.sourceRequestID, requestID);
        assert.equal(delivered.envelope, redelivery.envelope);
        const redeliveryPath = `${invite}/${recipient.userID}/${redelivery.requestID}`;
        assert.equal((await call(r, redeliveryPath, undefined, recipient.accessToken, 'DELETE')).status, 404);
        await call(r, '/api/auth/session', undefined, additional.accessToken, 'DELETE');
        const currentAdditional = await login(r, 'additional-device-recipient', additional.deviceID);
        assert.equal((await (await addressedInbox(currentAdditional)).json()).delivery, null);
        assert.ok((await (await discover(currentAdditional)).json()).requestIDs.includes(requestID));
        assert.equal((await submit(proof, currentAdditional)).status, 200);
        assert.equal((await (await addressedInbox(currentAdditional)).json()).delivery.requestID, redelivery.requestID);
        assert.equal((await call(r, original, undefined, sender.accessToken, 'DELETE')).status, 200);
        assert.equal((await (await addressedInbox(currentAdditional)).json()).delivery, null);
        assert.deepEqual(await (await call(r, redeliveryPath, undefined, currentAdditional.accessToken, 'DELETE')).json(), { status: 'cancelled' });
        assert.equal((await sendAgain({ ...redelivery, requestID: randomUUID() })).status, 403);
        assert.equal((await read()).status, 404);
        assert.equal((await submit(proof, currentAdditional)).status, 404);
        assert.equal((await (await call(r, original, undefined, recipient.accessToken, 'GET')).json()).status, 'received',
            'The withdrawal closes additional devices without rewriting the old receipt');

        const validOtherProof = makeProof(secondID);
        assert.equal((await submit(validOtherProof, currentAdditional, otherPath)).status, 200);
        assert.deepEqual(await (await read(sender, otherPath)).json(), addresses);
        await call(r, '/api/auth/session', undefined, currentAdditional.accessToken, 'DELETE');
        assert.deepEqual(await (await read(sender, otherPath)).json(), { devices: [] });
        const renewed = await login(r, 'additional-device-recipient', additional.deviceID);
        assert.deepEqual(await (await discover(renewed)).json(), { requestIDs: [secondID] });
        assert.equal((await submit(validOtherProof, renewed, otherPath)).status, 200);
        assert.deepEqual(await (await read(sender, otherPath)).json(), addresses);
        const lastDeliveryID = randomUUID();
        assert.equal((await sendAgain({ ...redelivery, requestID: lastDeliveryID, sourceRequestID: secondID, noticeID: secondID })).status, 200);
        const lastPath = `${invite}/${recipient.userID}/${lastDeliveryID}`;
        assert.deepEqual(await (await call(r, lastPath, undefined, renewed.accessToken, 'DELETE')).json(), { status: 'received' });
        await call(r, `/api/notifications/grants/${groupGrant.grantID}`, undefined, recipient.accessToken, 'DELETE');
        assert.equal((await read(sender, otherPath)).status, 404);
        assert.equal((await submit(validOtherProof, renewed, otherPath)).status, 404);
        assert.deepEqual(await (await discover(renewed)).json(), { requestIDs: [] });
    } finally { await r.dispose(); }
});

test('a new device finds its own live invitations without an earlier notification or contact list', async () => {
    const r = await setup();
    try {
        const sender = await login(r, 'invitation-discovery-sender');
        const secondSender = await login(r, 'invitation-discovery-other-sender');
        const oldDevice = await login(r, 'invitation-discovery-recipient');
        const newDevice = await login(r, 'invitation-discovery-recipient');
        const stranger = await login(r, 'invitation-discovery-stranger');
        const invite = '/api/notifications/group-invitations';
        const grantFor = async author => {
            const response = await call(r, `${invite}/grants`, { senderUserID: author.userID }, oldDevice.accessToken);
            assert.equal(response.status, 200);
            return (await response.json()).capability;
        };
        const firstGrant = await grantFor(sender), secondGrant = await grantFor(secondSender);
        const sharedNotice = randomUUID(), oldKey = 'a'.repeat(87), anotherOldKey = 'b'.repeat(87), newKey = 'c'.repeat(87);
        const put = async (author, capability, recipientKey, noticeID = randomUUID()) => {
            const requestID = randomUUID();
            const response = await call(r, invite, { capability, recipientKey, requestID, noticeID, expiresAt: Date.now() + 60_000,
                envelope: Buffer.from('opaque invitation').toString('base64') }, author.accessToken);
            assert.equal(response.status, 200);
            return requestID;
        };
        const original = await put(sender, firstGrant, oldKey, sharedNotice);
        const duplicate = await put(sender, firstGrant, anotherOldKey, sharedNotice);
        const independent = await put(secondSender, secondGrant, oldKey, sharedNotice);
        const alreadyAddressed = await put(sender, firstGrant, newKey);
        const cancelled = await put(sender, firstGrant, oldKey);
        const recordPath = id => `${invite}/${oldDevice.userID}/${id}`;
        assert.equal((await call(r, recordPath(original), undefined, oldDevice.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(r, recordPath(cancelled), undefined, sender.accessToken, 'DELETE')).status, 200);
        const discover = (user, key = newKey) => call(r, `${invite}/additional-devices?recipientKey=${key}`, undefined, user.accessToken, 'GET');
        assert.equal((await discover(newDevice, 'invalid')).status, 400);
        const found = await discover(newDevice);
        assert.equal(found.status, 200);
        const result = await found.json();
        assert.deepEqual(Object.keys(result), ['requestIDs']);
        assert.equal(result.requestIDs.length, 2, 'A notice is returned once per original sender');
        assert.ok(result.requestIDs.includes(independent));
        assert.ok(result.requestIDs.includes(original) || result.requestIDs.includes(duplicate));
        assert.ok(!result.requestIDs.includes(cancelled));
        assert.deepEqual(await (await discover(stranger)).json(), { requestIDs: [] });
        assert.deepEqual(await (await discover(oldDevice, oldKey)).json(), { requestIDs: [alreadyAddressed] },
            'Skip a notice if it already has a delivery to this key');
    } finally { await r.dispose(); }
});
