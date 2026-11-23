import { test } from 'node:test';
import WebSocket from 'ws';
import assert from 'node:assert/strict';
import { createHash, createPrivateKey, createPublicKey, hkdfSync, randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeJwt, generateKeyPair, exportJWK, exportPKCS8, SignJWT, jwtVerify } from 'jose';
import { makeRuntime, offer, room, provider, sealInvitationSubmission } from './support/runtime.mjs';

const keys = await generateKeyPair('RS256');
const publicKey = { ...await exportJWK(keys.publicKey), kid: 'apple-fixture', alg: 'RS256', use: 'sig' };
const audience = 'com.yowamushi-inc.RideIntercom.RideIntercom';
const options = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: audience };
const attestationOptions = { ...options, DEVICE_ATTESTATION_ENABLED: 'true',
    DEVICE_ATTESTATION_MAC_POLICY: JSON.stringify({ appID: `FIXTURE123.${audience}`,
        environment: 'development', validationCategory: 3, bundleVersion: null }) };
const appleClientKeys = await generateKeyPair('ES256', { extractable: true });
const appleClientConfiguration = {
    APPLE_SIGN_IN_PRIVATE_KEY: await exportPKCS8(appleClientKeys.privateKey),
    APPLE_SIGN_IN_KEY_ID: 'SIGNINKEY1',
    APPLE_TEAM_ID: 'TEAMID1234'
};
const call = (runtime, path, body, token, method = 'POST') => runtime.dispatchFetch(`https://worker.test${path}`, {
    method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
});
async function challenge(runtime, deviceID = randomUUID()) {
    const response = await call(runtime, '/api/auth/apple/challenge', { deviceID });
    assert.equal(response.status, 200);
    return { ...await response.json(), deviceID };
}
async function proof(attempt, changes = {}, privateKey = keys.privateKey) {
    return new SignJWT({ nonce: attempt.nonce, email: 'private@example.invalid',
        iss: 'https://appleid.apple.com', aud: audience, sub: 'apple-private-subject',
        iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 300, ...changes })
        .setProtectedHeader({ alg: 'RS256', kid: 'apple-fixture' }).sign(privateKey);
}
async function signIn(runtime, attempt, changes) {
    return call(runtime, '/api/auth/apple/session', { challengeID: attempt.challengeID, identityToken: await proof(attempt, changes) });
}

test('Apple enrollment gives one account across devices and authorizes individual device credentials', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const a = await challenge(runtime), b = await challenge(runtime);
        const first = await signIn(runtime, a), second = await signIn(runtime, b);
        assert.equal(first.status, 200); assert.equal(second.status, 200);
        const one = await first.json(), two = await second.json();
        assert.equal(one.userID, two.userID);
        assert.match(one.userID, /^[a-f0-9]{64}$/);
        assert.notEqual(one.userID, one.accessToken.split('.')[1], 'Public identity must not expose the private account locator');
        assert.equal(one.deviceID, a.deviceID);
        assert.notEqual(one.accessToken, two.accessToken);
        assert.ok(!JSON.stringify(one).includes('apple-private-subject'));
        assert.ok(!JSON.stringify(one).includes('private@example.invalid'));
        const session = await call(runtime, '/api/auth/session', undefined, one.accessToken, 'GET');
        assert.equal(session.status, 200);
        assert.deepEqual(await session.json(), { userID: one.userID, deviceID: a.deviceID, expiresAt: one.expiresAt });
        assert.equal((await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).status, 200);
        const joined = await call(runtime, `/api/rooms/${room}/join`, { participantId: a.deviceID, offer }, one.accessToken);
        assert.equal(joined.status, 200);
        const media = await joined.json();
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}/renew`, {}, two.accessToken)).status, 403);
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}`, undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/status', undefined, two.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});

test('Apple proof rejects invalid claims and signatures without consuming the valid attempt', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        for (const claims of [{ nonce: 'wrong' }, { aud: 'another-app' }, { iss: 'https://attacker.invalid' },
            { exp: 1 }, { sub: '' }, { iat: Math.floor(Date.now() / 1000) + 3600 }, { nonce: undefined }]) {
            const attempt = await challenge(runtime);
            assert.equal((await signIn(runtime, attempt, claims)).status, 401);
        }
        const attempt = await challenge(runtime);
        const other = await generateKeyPair('RS256');
        assert.equal((await call(runtime, '/api/auth/apple/session', {
            challengeID: attempt.challengeID, identityToken: await proof(attempt, {}, other.privateKey)
        })).status, 401);
        assert.equal((await signIn(runtime, attempt)).status, 200);
        assert.equal((await signIn(runtime, attempt)).status, 401);
    } finally { await runtime.dispose(); }
});

test('a concurrent replay issues only one device credential', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const body = { challengeID: attempt.challengeID, identityToken: await proof(attempt) };
        const results = await Promise.all([call(runtime, '/api/auth/apple/session', body), call(runtime, '/api/auth/apple/session', body)]);
        assert.deepEqual(results.map(r => r.status).sort(), [200, 401]);
    } finally { await runtime.dispose(); }
});

test('signing in again rotates only that device and another Apple user gets another account', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const old = await (await signIn(runtime, attempt)).json();
        const next = await (await signIn(runtime, await challenge(runtime, attempt.deviceID))).json();
        const other = await (await signIn(runtime, await challenge(runtime), { sub: 'another-apple-subject' })).json();
        assert.equal(old.userID, next.userID);
        assert.notEqual(old.userID, other.userID);
        assert.equal((await call(runtime, '/api/status', undefined, old.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/status', undefined, next.accessToken, 'GET')).status, 200);
        const parts = next.accessToken.split('.'); parts[2] = other.deviceID;
        assert.equal((await call(runtime, '/api/status', undefined, parts.join('.'), 'GET')).status, 401);
    } finally { await runtime.dispose(); }
});

test('enrollment fails closed without explicit enablement and invalid request bodies are bounded', async () => {
    const runtime = await makeRuntime();
    const enabled = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        assert.equal((await call(runtime, '/api/auth/apple/challenge', { deviceID: randomUUID() })).status, 503);
        for (const deviceID of ['', 1, '../device', 'x'.repeat(1000)]) {
            assert.equal((await call(enabled, '/api/auth/apple/challenge', { deviceID })).status, 400);
        }
        assert.equal((await call(enabled, '/api/auth/apple/session', { challengeID: 'bad', identityToken: 'x' })).status, 400);
        assert.equal((await call(enabled, '/api/auth/apple/challenge', { deviceID: randomUUID(), excess: 'x'.repeat(66000) })).status, 400);
    } finally { await runtime.dispose(); await enabled.dispose(); }
});

test('device secrets, Apple tokens, subject and email are not persisted', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-privacy-'));
    const runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const identityToken = await proof(attempt);
        const response = await call(runtime, '/api/auth/apple/session', { challengeID: attempt.challengeID, identityToken });
        assert.equal(response.status, 200);
        const session = await response.json();
        const files = (await readdir(storageDirectory, { recursive: true })).filter(path => /\.sqlite(?:-wal)?$/.test(path));
        const bytes = Buffer.concat(await Promise.all(files.map(path => readFile(join(storageDirectory, path)))));
        assert.ok(bytes.includes(Buffer.from(attempt.deviceID)));
        for (const secret of [identityToken, session.accessToken.split('.').at(-1), 'apple-private-subject', 'private@example.invalid']) {
            assert.ok(!bytes.includes(Buffer.from(secret)));
        }
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('expired challenges and devices remain unusable after server restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-expiry-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 301000 });
        assert.equal((await signIn(runtime, attempt)).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'GET')).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 31 * 86400000 });
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'GET')).status, 401);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('the device attestation challenge is opt-in and belongs to a live device credential', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    const enabled = await makeRuntime(attestationOptions, { appleKeys: [publicKey] });
    const path = '/api/auth/device-attestation/challenge';
    try {
        const disabled = await (await signIn(runtime, await challenge(runtime))).json();
        assert.equal((await call(runtime, path, undefined, disabled.accessToken)).status, 503);
        assert.equal((await call(enabled, path)).status, 401);
        const first = await (await signIn(enabled, await challenge(enabled))).json();
        const second = await (await signIn(enabled, await challenge(enabled))).json();
        assert.equal(first.userID, second.userID);
        assert.equal((await call(enabled, path, undefined, first.accessToken, 'GET')).status, 405);
        assert.equal((await call(enabled, path, { deviceID: second.deviceID }, first.accessToken)).status, 400);

        const requestChallenge = async token => {
            const response = await call(enabled, path, {}, token);
            assert.equal(response.status, 200);
            assert.equal(response.headers.get('Cache-Control'), 'no-store');
            return response.json();
        };
        const [issued, repeated] = await Promise.all([requestChallenge(first.accessToken), requestChallenge(first.accessToken)]);
        const independent = await requestChallenge(second.accessToken);
        assert.deepEqual(repeated, issued);
        assert.match(issued.nonce, /^[a-f0-9]{64}$/);
        assert.notEqual(independent.nonce, issued.nonce);

        const renewed = await (await signIn(enabled, await challenge(enabled, first.deviceID))).json();
        assert.equal((await call(enabled, path, undefined, first.accessToken)).status, 401);
        assert.notEqual((await requestChallenge(renewed.accessToken)).nonce, issued.nonce);
        assert.deepEqual(await requestChallenge(second.accessToken), independent);
        assert.equal((await call(enabled, '/api/auth/session', undefined, renewed.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(enabled, path, undefined, renewed.accessToken)).status, 401);
        const signedInAgain = await (await signIn(enabled, await challenge(enabled, first.deviceID))).json();
        assert.notEqual((await requestChallenge(signedInAgain.accessToken)).nonce, issued.nonce);
    } finally { await runtime.dispose(); await enabled.dispose(); }
});

const missingRegistrationSettings = [
    ['missing policy', { ...attestationOptions, DEVICE_ATTESTATION_MAC_POLICY: '' }, true],
    ['invalid policy', { ...attestationOptions, DEVICE_ATTESTATION_MAC_POLICY: '{}' }, true],
    ['missing key index', attestationOptions, false]
];

for (const [condition, config, appAttestationIndex] of missingRegistrationSettings) {
    test(`both attestation routes reject ${condition} before processing requests`, async () => {
        const runtime = await makeRuntime(config, { appleKeys: [publicKey], appAttestationIndex });
        try {
            const device = await (await signIn(runtime, await challenge(runtime))).json();
            for (const path of ['/api/auth/device-attestation/challenge', '/api/auth/device-attestation']) {
                assert.equal((await call(runtime, path, {}, device.accessToken)).status, 503);
                assert.equal((await call(runtime, path)).status, 503);
            }
            assert.equal((await call(runtime, '/api/auth/session', undefined, device.accessToken, 'GET')).status, 200);
        } finally { await runtime.dispose(); }
    });
}

test('the device attestation challenge survives restart and rotates at its original deadline', async () => {
    const start = Date.now();
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-attestation-challenge-'));
    const newRuntime = fixedNowMs => makeRuntime(attestationOptions, { storageDirectory, fixedNowMs, appleKeys: [publicKey] });
    let runtime = await newRuntime(start);
    const path = '/api/auth/device-attestation/challenge';
    try {
        const device = await (await signIn(runtime, await challenge(runtime))).json();
        const requestChallenge = async () => {
            const response = await call(runtime, path, {}, device.accessToken);
            assert.equal(response.status, 200);
            return response.json();
        };
        const issued = await requestChallenge();
        assert.equal(issued.expiresAt, start + 300_000);
        await runtime.dispose();
        runtime = await newRuntime(issued.expiresAt - 1);
        assert.deepEqual(await requestChallenge(), issued);
        await runtime.dispose();
        runtime = await newRuntime(issued.expiresAt);
        const next = await requestChallenge();
        assert.notEqual(next.nonce, issued.nonce);
        assert.equal(next.expiresAt, issued.expiresAt + 300_000);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('device registration is bounded and a full account can still rotate an existing device', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const first = await challenge(runtime);
        assert.equal((await signIn(runtime, first)).status, 200);
        for (let n = 1; n < 8; n++) assert.equal((await signIn(runtime, await challenge(runtime))).status, 200);
        const full = await signIn(runtime, await challenge(runtime));
        assert.equal(full.status, 409);
        assert.equal((await full.json()).code, 'device_limit_reached');
        assert.equal((await signIn(runtime, await challenge(runtime, first.deviceID))).status, 200);
    } finally { await runtime.dispose(); }
});

test('media pause does not prevent a signed-in device from revoking its credential', async () => {
    const runtime = await makeRuntime({ ...options, SERVICE_ENABLED: 'false' }, { appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        assert.equal((await call(runtime, '/api/status', undefined, session.accessToken, 'GET')).status, 503);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
});

test('enrollment limits requests before parsing and ignores client-selected forwarding identifiers', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        // Invalid input consumes the same source budget as valid input. Changing
        // device IDs, route, or X-Forwarded-For cannot reset that budget.
        for (let n = 0; n < 31; n++) {
            const response = await runtime.dispatchFetch(`https://worker.test/api/auth/apple/${n % 2 ? 'session' : 'challenge'}`, {
                method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.10', 'X-Forwarded-For': `198.51.100.${n}` }, body: '{}'
            });
            assert.equal(response.status, n < 30 ? 400 : 429);
            if (n === 30) {
                assert.equal(response.headers.get('Retry-After'), '60');
                assert.equal(response.headers.get('Cache-Control'), 'no-store');
                assert.equal((await response.json()).code, 'enrollment_rate_limited');
            }
        }
        assert.equal((await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
            method: 'POST', headers: { 'CF-Connecting-IP': '192.0.2.11' }, body: JSON.stringify({ deviceID: randomUUID() })
        })).status, 200);
        assert.equal((await call(runtime, '/health', undefined, undefined, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});

test('aggregate enrollment limit also bounds changing source addresses', async () => {
    const runtime = await makeRuntime(options);
    try {
        for (let n = 0; n < 301; n++) {
            const response = await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
                method: 'POST', headers: { 'CF-Connecting-IP': `2001:db8::${n.toString(16)}` }, body: '{}'
            });
            assert.equal(response.status, n < 300 ? 400 : 429);
        }
    } finally { await runtime.dispose(); }
});

test('missing abuse protection fails closed while session revocation stays available', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-limit-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        assert.equal((await runtime.dispatchFetch('https://worker.test/api/auth/apple/challenge', {
            // Miniflare fills an absent/empty source header; an invalid edge
            // value exercises the same fail-closed branch without that default.
            method: 'POST', headers: { 'CF-Connecting-IP': 'x'.repeat(65) }, body: JSON.stringify({ deviceID: randomUUID() })
        })).status, 503);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, enrollmentLimits: false });
        assert.equal((await challengeResponse(runtime)).status, 503);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});
const challengeResponse = runtime => call(runtime, '/api/auth/apple/challenge', { deviceID: randomUUID() });

test('challenge verification attempts are bounded across concurrent requests and restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-attempts-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const attempt = await challenge(runtime);
        const replies = await Promise.all(Array.from({ length: 5 }, () => signIn(runtime, attempt, { nonce: 'wrong' })));
        assert.ok(replies.every(response => response.status === 401));
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await signIn(runtime, attempt)).status, 401);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('throttling enrollment never blocks authenticated sign-out or existing service access', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const session = await (await signIn(runtime, await challenge(runtime))).json();
        for (let n = 0; n < 30; n++) await challengeResponse(runtime);
        assert.equal((await challengeResponse(runtime)).status, 429);
        assert.equal((await call(runtime, '/api/status', undefined, session.accessToken, 'GET')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, session.accessToken, 'DELETE')).status, 200);
    } finally { await runtime.dispose(); }
});

async function enrolled(runtime, sub = 'apple-private-subject') {
    const response = await signIn(runtime, await challenge(runtime), { sub });
    assert.equal(response.status, 200);
    return response.json();
}

const replyPath = '/api/ordinary-group-replies';
const replySlot = () => randomBytes(32).toString('hex');
const replyPacket = () => randomBytes(64).toString('base64');

async function signReplyDevice(runtime, user, memberID) {
    const key = await generateKeyPair('ES256', { extractable: true });
    const jwk = await exportJWK(key.publicKey);
    const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64url');
    const issued = await call(runtime, '/api/auth/identity', { memberID, deviceKey: publicKey }, user.accessToken);
    assert.equal(issued.status, 200);
    const certificate = await issued.json();
    const hash = value => createHash('sha256').update(value).digest('hex');
    const sessionBinding = hash(hash(user.accessToken.split('.')[3]));
    const proof = async (purpose, payload) => {
        const fields = [purpose, memberID, publicKey, certificate.certificate, certificate.issuerKey, payload];
        const parts = [Buffer.from('rideintercom.device-proof.v1\0')];
        for (const field of fields) {
            const value = Buffer.from(field), length = Buffer.alloc(4);
            length.writeUInt32BE(value.length);
            parts.push(length, value);
        }
        const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key.privateKey, Buffer.concat(parts));
        return { publicKey, certificate, signature: Buffer.from(signature).toString('base64url') };
    };
    return { sessionBinding, proof, relayKey: decodeJwt(certificate.certificate).invitationRelayKey };
}

const directRestorePath = '/api/direct-call-restore/relay';

async function signRestoreRelay(value, identity) {
    const { recipient, deviceID, sessionBinding, id, expiresAt, packet } = value;
    const proof = await identity.proof('submitDirectCallRestoreRelay',
        JSON.stringify([recipient, deviceID, sessionBinding, id, expiresAt, packet]));
    return { ...value, proof };
}

test('direct restore relay is unavailable without explicit test enablement', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const device = await enrolled(runtime);
        assert.equal((await call(runtime, directRestorePath, undefined, device.accessToken, 'GET')).status, 404);
        assert.equal((await call(runtime, directRestorePath, {}, device.accessToken, 'PUT')).status, 404);
        assert.equal((await call(runtime, '/api/direct-call-restore/device', {}, device.accessToken, 'POST')).status, 404);
    } finally { await runtime.dispose(); }
});

test('direct restore device lookup scopes opaque publications to the authorized account and session', async () => {
    const path = '/api/direct-call-restore/device';
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const runtime = await makeRuntime({ ...options, DIRECT_CALL_RESTORE_RELAY_ENABLED: 'true',
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey)) },
    { appleKeys: [publicKey], adjustableClock: true });
    try {
        const owner = await enrolled(runtime, 'lookup-owner');
        const otherOwnerDevice = await enrolled(runtime, 'lookup-owner');
        const reader = await enrolled(runtime, 'lookup-reader');
        const replacementReader = await enrolled(runtime, 'lookup-reader');
        const stranger = await enrolled(runtime, 'lookup-stranger');
        const identity = await signReplyDevice(runtime, owner, 'lookup-owner');
        const siblingIdentity = await signReplyDevice(runtime, otherOwnerDevice, 'lookup-owner-sibling');
        const issuedAt = Date.now();
        const initial = { slot: replySlot(), reader: reader.userID, issuedAt, expiresAt: issuedAt + 150_000,
            packet: randomBytes(64).toString('base64') };
        const signed = async (value, signer = identity) => ({ ...value, proof: await signer.proof('publishDirectRestoreDevice',
            JSON.stringify([value.slot, value.reader, value.issuedAt, value.expiresAt, value.packet])) });
        const write = (body, device = owner) => call(runtime, path, body, device.accessToken, 'PUT');
        const read = (device, slot = initial.slot) => call(runtime, path, { owner: owner.userID, slot }, device.accessToken);
        const revoke = (slot, device = owner) => call(runtime, path, { slot, reader: reader.userID }, device.accessToken, 'DELETE');
        const update = async value => assert.deepEqual(await (await write(await signed(value))).json(), { state: 'stored' });

        assert.equal((await read(reader)).status, 404);
        const first = await signed(initial);
        assert.equal((await write({ ...first, reader: stranger.userID })).status, 401);
        assert.equal((await write({ ...first, packet: randomBytes(64).toString('base64') })).status, 401);
        await update(initial);
        await update(initial);
        assert.deepEqual(await (await read(reader)).json(), { expiresAt: initial.expiresAt, packet: initial.packet });
        assert.deepEqual(await (await read(replacementReader)).json(), { expiresAt: initial.expiresAt, packet: initial.packet });
        assert.equal((await read(stranger)).status, 404);
        assert.equal((await read(reader, replySlot())).status, 404);
        assert.equal((await revoke(initial.slot, otherOwnerDevice)).status, 409);
        const newer = { ...initial, issuedAt: issuedAt + 1, expiresAt: issuedAt + 180_000,
            packet: randomBytes(64).toString('base64') };
        assert.equal((await write(await signed(newer, siblingIdentity), otherOwnerDevice)).status, 409);
        await update(newer);
        assert.equal((await write(first)).status, 409);
        assert.deepEqual(await (await read(reader)).json(), { expiresAt: newer.expiresAt, packet: newer.packet });
        assert.deepEqual(await (await revoke(initial.slot)).json(), { state: 'revoked' });
        assert.deepEqual(await (await revoke(initial.slot)).json(), { state: 'revoked' });
        assert.equal((await read(reader)).status, 404);
        assert.equal((await write(await signed(newer))).status, 409);

        const overtaken = { ...initial, slot: replySlot() };
        assert.deepEqual(await (await revoke(overtaken.slot)).json(), { state: 'revoked' });
        assert.equal((await write(await signed(overtaken))).status, 409);
        assert.equal((await read(reader, overtaken.slot)).status, 404);
        const briefly = { ...initial, slot: replySlot(), expiresAt: issuedAt + 30_000 };
        const longer = { ...initial, slot: replySlot() };
        await update(briefly);
        await update(longer);
        assert.equal((await write(await signed({ ...longer, expiresAt: issuedAt + 86_400_001 }))).status, 400);
        assert.equal((await write(await signed({ ...longer, issuedAt: issuedAt + 120_000 }))).status, 400);
        for (let index = 0; index < 60; index += 1) await update({ ...longer, slot: replySlot() });
        const excess = { ...longer, slot: replySlot() };
        assert.equal((await write(await signed(excess))).status, 429);
        assert.equal((await revoke(excess.slot)).status, 429);
        await runtime.advanceClock(31_000);
        assert.equal((await read(reader, briefly.slot)).status, 404);
        await update(excess);
        assert.equal((await read(reader, longer.slot)).status, 200);
        const renewedSession = await signIn(runtime, await challenge(runtime, owner.deviceID), { sub: 'lookup-owner' });
        assert.equal(renewedSession.status, 200);
        const renewed = await renewedSession.json();
        assert.equal((await read(reader, longer.slot)).status, 404);
        assert.equal((await write(await signed(longer), renewed)).status, 401);
        const renewedIdentity = await signReplyDevice(runtime, renewed, 'lookup-owner');
        const current = { ...longer, issuedAt: Date.now(), expiresAt: Date.now() + 150_000 };
        assert.equal((await write(await signed(current, renewedIdentity), renewed)).status, 200);
        assert.equal((await read(reader, longer.slot)).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, renewed.accessToken, 'DELETE')).status, 200);
        assert.equal((await read(reader, longer.slot)).status, 404);
        assert.equal((await call(runtime, '/api/auth/account', undefined, otherOwnerDevice.accessToken, 'DELETE')).status, 200);
        assert.equal((await read(replacementReader, longer.slot)).status, 404);
    } finally { await runtime.dispose(); }
});

test('direct restore relay preserves opaque packets only for the addressed current device session', async () => {
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const runtime = await makeRuntime({ ...options, DIRECT_CALL_RESTORE_RELAY_ENABLED: 'true',
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey)) },
    { appleKeys: [publicKey], adjustableClock: true });
    try {
        const sender = await enrolled(runtime, 'restore-source');
        const recipient = await enrolled(runtime, 'restore-target');
        const spare = await enrolled(runtime, 'restore-target');
        const author = await signReplyDevice(runtime, sender, 'restore-source');
        const target = await signReplyDevice(runtime, recipient, 'restore-target');
        const destination = { recipient: recipient.userID, deviceID: recipient.deviceID,
            sessionBinding: target.sessionBinding, expiresAt: Date.now() + 180_000 };
        const value = { ...destination, id: randomUUID(), packet: randomBytes(64).toString('base64') };
        const exact = await signRestoreRelay(value, author);
        const put = body => call(runtime, directRestorePath, body, sender.accessToken, 'PUT');
        const read = device => call(runtime, directRestorePath, undefined, device.accessToken, 'GET');
        const retire = device => call(runtime, directRestorePath, { id: value.id }, device.accessToken, 'DELETE');

        assert.equal((await put({ ...exact, packet: randomBytes(64).toString('base64') })).status, 401);
        const wrongSession = await signRestoreRelay({ ...value, sessionBinding: author.sessionBinding }, author);
        assert.equal((await put(wrongSession)).status, 404);
        assert.deepEqual(await (await put(exact)).json(), { state: 'queued' });
        assert.deepEqual(await (await put(exact)).json(), { state: 'queued' });
        const changed = await signRestoreRelay({ ...value, packet: randomBytes(64).toString('base64') }, author);
        assert.equal((await put(changed)).status, 409);
        assert.deepEqual(await (await read(spare)).json(), { messages: [] });
        assert.deepEqual(await (await read(sender)).json(), { messages: [] });
        const envelope = { id: value.id, senderUserID: sender.userID, expiresAt: value.expiresAt, packet: value.packet };
        assert.deepEqual(await (await read(recipient)).json(), { messages: [envelope] });
        assert.equal((await retire(spare)).status, 404);
        assert.deepEqual(await (await retire(recipient)).json(), { state: 'retired' });
        assert.deepEqual(await (await put(exact)).json(), { state: 'retired' });
        assert.deepEqual(await (await read(recipient)).json(), { messages: [] });

        const pending = await signRestoreRelay({ ...value, id: randomUUID() }, author);
        assert.equal((await put(pending)).status, 200);
        for (let slot = 0; slot < 6; slot += 1) {
            const another = await signRestoreRelay({ ...value, id: randomUUID() }, author);
            assert.equal((await put(another)).status, 200);
        }
        const overCapacity = await signRestoreRelay({ ...value, id: randomUUID() }, author);
        assert.equal((await put(overCapacity)).status, 429);
        assert.equal((await (await read(recipient)).json()).messages.length, 7);
        await runtime.advanceClock(181_000);
        assert.deepEqual(await (await read(recipient)).json(), { messages: [] });
        assert.equal((await put(pending)).status, 400);

        const freshExpiry = Date.now() + 241_000;
        const waiting = await signRestoreRelay({ ...value, expiresAt: freshExpiry, id: randomUUID() }, author);
        assert.equal((await put(waiting)).status, 200);
        const rotated = await signIn(runtime, await challenge(runtime, recipient.deviceID), { sub: 'restore-target' });
        assert.equal(rotated.status, 200);
        const current = await rotated.json();
        assert.equal((await read(recipient)).status, 401);
        assert.deepEqual(await (await read(current)).json(), { messages: [] });
        assert.equal((await put(waiting)).status, 404);

        const currentTarget = await signReplyDevice(runtime, current, 'restore-target');
        const forCurrent = await signRestoreRelay({ ...value, expiresAt: freshExpiry, id: randomUUID(),
            sessionBinding: currentTarget.sessionBinding }, author);
        assert.equal((await put(forCurrent)).status, 200);
        assert.equal((await (await read(current)).json()).messages.length, 1);
        assert.equal((await call(runtime, '/api/auth/session', undefined, sender.accessToken, 'DELETE')).status, 200);
        assert.deepEqual(await (await read(current)).json(), { messages: [] });
    } finally { await runtime.dispose(); }
});

async function signBackgroundSubmission(body, sender, identity, origin, purpose) {
    const submission = Buffer.from(JSON.stringify(body)).toString('base64');
    const { sessionBinding } = identity;
    return { senderUserID: sender.userID, deviceID: sender.deviceID, sessionBinding, submission,
        proof: await identity.proof(purpose, JSON.stringify([origin, sessionBinding, submission])) };
}

test('background contact deletion publishes to the same mailbox and cannot revive a retired deletion', async () => {
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const r = await makeRuntime({
        ...options, NOTIFICATIONS_ENABLED: 'false', INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url'),
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey))
    }, { appleKeys: [publicKey], apns: async () => { throw new Error('Unexpected notification delivery'); } });
    try {
        const sender = await enrolled(r, 'background-deletion-sender');
        const recipient = await enrolled(r, 'background-deletion-recipient');
        const senderDevice = await signReplyDevice(r, sender, 'background-deletion-sender');
        const recipientDevice = await signReplyDevice(r, recipient, 'background-deletion-recipient');
        const slot = replySlot(), id = randomUUID(), expiresAt = Date.now() + 60_000;
        const readProof = await recipientDevice.proof('readContactDeletion', JSON.stringify([sender.userID, slot]));
        const packet = Buffer.alloc(64, 17).toString('base64');
        const notice = { slot, id, expiresAt, recipient: recipient.userID, recipientKey: readProof.publicKey, packet };
        const read = { owner: sender.userID, slot, proof: readProof };
        const path = '/api/contact-deletions';
        const endpoint = `${path}/background-publish`;
        const signed = (body, purpose = 'publishBackgroundContactDeletion') =>
            signBackgroundSubmission(body, sender, senderDevice, 'https://worker.test', purpose);
        const send = async body => call(r, endpoint, { sealed: await sealInvitationSubmission(body, senderDevice.relayKey) });
        const state = async (response, expected) => {
            assert.equal(response.status, 200);
            assert.deepEqual(await response.json(), { state: expected });
        };
        const publication = await signed(notice);
        await state(await send(publication), 'pending');
        await state(await send(publication), 'pending');
        assert.deepEqual(await (await call(r, `${path}/read`, read, recipient.accessToken)).json(),
            { deletion: { id, expiresAt, packet } });
        assert.equal((await send(await signed(notice, 'submitBackgroundContactInvitationAcceptance'))).status, 401);
        assert.equal((await send(await signed({ ...notice, unexpected: 'fixture' }))).status, 400);
        assert.equal((await send(await signed({ ...notice, expiresAt: Date.now() - 1 }))).status, 400);
        assert.equal((await call(r, endpoint, publication, sender.accessToken)).status, 400);

        await state(await call(r, path, { slot, id, expiresAt }, sender.accessToken, 'DELETE'), 'retired');
        await state(await send(publication), 'retired');
        assert.equal((await call(r, `${path}/read`, read, recipient.accessToken)).status, 404);

        const retiredSession = await call(r, '/api/auth/account', undefined, sender.accessToken, 'DELETE');
        assert.equal(retiredSession.status, 200);
        assert.equal((await send(publication)).status, 401);
    } finally { await r.dispose(); }
});

test('a background contact acceptance is limited to the originally signed reply and current device', async () => {
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-background-reply-'));
    const r = await makeRuntime({ ...options, NOTIFICATIONS_ENABLED: 'false', INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url'),
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey)) },
        { appleKeys: [publicKey], trackReplyStorage: true, storageDirectory });
    try {
        const a = await enrolled(r, 'background-reply-author'), b = await enrolled(r, 'background-reply-recipient');
        const author = await signReplyDevice(r, a, 'background-reply-author');
        const receiver = await signReplyDevice(r, b, 'background-reply-recipient');
        const origin = 'https://worker.test';
        const slot = replySlot(), expiresAt = Date.now() + 60_000;
        const signedAdmission = async (mailbox, expiry) => ({
            deviceID: a.deviceID, sessionBinding: author.sessionBinding, expiresAt: expiry,
            proof: await author.proof('openContactInvitationReply', JSON.stringify([origin, author.sessionBinding, mailbox, expiry]))
        });
        const value = { owner: a.userID, slot, expiresAt, id: randomUUID(), packet: replyPacket(), admission: await signedAdmission(slot, expiresAt) };
        const signed = (body = value, target = origin, purpose = 'submitBackgroundContactInvitationAcceptance') =>
            signBackgroundSubmission(body, b, receiver, target, purpose);
        const endpoint = `${replyPath}/background-acceptance`;
        const submit = async body => call(r, endpoint, { sealed: await sealInvitationSubmission(body, receiver.relayKey) });
        const inbox = () => call(r, `${replyPath}/inbox`, { slot }, a.accessToken);
        const exact = await signed();
        assert.equal((await inbox()).status, 404);
        assert.equal((await call(r, endpoint, exact)).status, 400, 'the background contact route has no unsealed submission');
        const sealed = await sealInvitationSubmission(exact, receiver.relayKey);
        const transferred = Buffer.concat(sealed.split('.').map(part => Buffer.from(part, 'base64url')));
        for (const marker of [slot, value.id, a.userID, b.userID, b.deviceID, exact.proof.signature]) {
            assert.equal(transferred.includes(Buffer.from(marker)), false, 'the OS transfer excludes readable invitation metadata');
        }
        const segments = sealed.split('.');
        const ciphertext = Buffer.from(segments[3], 'base64url');
        ciphertext[0] ^= 1;
        segments[3] = ciphertext.toString('base64url');
        assert.equal((await call(r, endpoint, { sealed: segments.join('.') })).status, 401);
        assert.equal((await r.dispatchFetch(`https://preview.worker.test${endpoint}`, {
            method: 'POST', headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10' }, body: JSON.stringify({ sealed })
        })).status, 401);
        assert.equal((await inbox()).status, 404);
        const first = await submit(exact);
        assert.equal(first.status, 200);
        assert.deepEqual(await first.json(), { id: value.id, expiresAt });
        const accounts = await r.getDurableObjectNamespace('USER_ACCOUNT');
        const account = accounts.get(accounts.idFromString(a.accessToken.split('.')[1]));
        const before = JSON.parse(await account.replyStorageState());
        assert.equal((await submit(exact)).status, 200);
        assert.deepEqual(JSON.parse(await account.replyStorageState()), before);
        for (const changed of [{ slot: replySlot() }, { expiresAt: expiresAt + 1 }, { id: randomUUID() }, { owner: b.userID }, { packet: replyPacket() }]) {
            assert.equal((await submit({ ...exact, submission: Buffer.from(JSON.stringify({ ...value, ...changed })).toString('base64') })).status, 401);
        }
        assert.equal((await submit(await signed(value, 'https://foreign.test'))).status, 401);
        assert.equal((await submit(await signed(value, origin, 'submitBackgroundGroupInvitation'))).status, 401);
        for (const action of ['/acceptance', '/acknowledgement', '/inbox', '/receipt']) {
            const method = action === '/inbox' || action === '/receipt' ? 'POST' : 'PUT';
            assert.equal((await call(r, replyPath + action, exact, undefined, method)).status, 401);
        }
        assert.equal((await submit(await signed({ ...value, admission: undefined, expiresAt: expiresAt + 1 }))).status, 409);
        assert.equal((await submit(await signed({ ...value, admission: undefined, expiresAt: Date.now() - 1 }))).status, 400);
        const extraName = 'SyntheticPrivateReplyName';
        assert.equal((await submit(await signed({ ...value, extraName }))).status, 400);
        assert.deepEqual(await (await inbox()).json(), { acceptances: [{ id: value.id, packet: value.packet }] });
        const files = (await readdir(storageDirectory, { recursive: true }))
            .filter(path => path.includes('UserAccount') && /\.sqlite(?:-wal)?$/.test(path));
        assert.ok(files.length > 0, 'Account relay storage must be observed');
        const persisted = Buffer.concat(await Promise.all(files.map(path => readFile(join(storageDirectory, path)))));
        assert.ok(persisted.includes(Buffer.from(value.packet)), 'Inspect storage that actually contains the ciphertext');
        for (const nonStored of [extraName, slot, sealed, exact.submission, exact.proof.signature, a.accessToken, b.accessToken]) {
            assert.ok(!persisted.includes(Buffer.from(nonStored)), 'An unneeded input must not be persisted');
        }
        const receipt = { id: value.id, packet: replyPacket() };
        assert.equal((await call(r, `${replyPath}/acknowledgement`, { slot, ...receipt }, a.accessToken, 'PUT')).status, 200);
        assert.equal((await submit(exact)).status, 200);
        const lookup = { owner: a.userID, slot, id: value.id };
        assert.deepEqual(await (await call(r, `${replyPath}/receipt`, lookup, b.accessToken)).json(), { receipt });
        assert.equal((await submit(await signed({ ...value, admission: undefined }))).status, 200);
        assert.equal((await submit(await signed({ ...value, expiresAt: expiresAt + 1 }))).status, 400);

        const unopenedSlot = replySlot();
        const oldAdmission = await signedAdmission(unopenedSlot, expiresAt);
        const updatedAuthor = await signIn(r, await challenge(r, a.deviceID), { sub: 'background-reply-author' });
        assert.equal(updatedAuthor.status, 200);
        assert.equal((await submit(exact)).status, 200, 'a current receiver can use a matching existing mailbox');
        const otherExpiry = expiresAt + 1;
        const mismatched = { ...value, expiresAt: otherExpiry, admission: await signedAdmission(slot, otherExpiry) };
        assert.equal((await submit(await signed(mismatched))).status, 409, 'old admission cannot alter the saved mailbox expiry');
        assert.equal((await call(r, `${replyPath}/acceptance`, value, b.accessToken, 'PUT')).status, 401,
            'ordinary submission still requires a current opening permission');
        assert.equal((await submit(await signed({ ...value, slot: unopenedSlot, admission: oldAdmission }))).status, 401);

        const renewed = await signIn(r, await challenge(r, b.deviceID), { sub: 'background-reply-recipient' });
        assert.equal(renewed.status, 200);
        assert.equal((await submit(exact)).status, 401);
        const current = await renewed.json();
        const next = await signReplyDevice(r, current, 'background-reply-recipient');
        const proof = await next.proof('submitBackgroundContactInvitationAcceptance', JSON.stringify([origin, next.sessionBinding, exact.submission]));
        const accepted = await submit({ ...exact, sessionBinding: next.sessionBinding, proof });
        assert.equal(accepted.status, 200);
        assert.deepEqual(await (await call(r, `${replyPath}/receipt`, lookup, current.accessToken)).json(), { receipt });
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('background contact acceptance can use the previous relay key until the next period ends', async () => {
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const r = await makeRuntime({ ...options, INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url'),
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey)) }, { appleKeys: [publicKey], adjustableClock: true });
    try {
        const origin = 'https://worker.test', endpoint = `${replyPath}/background-acceptance`;
        const period = 30 * 86400_000, boundary = (Math.floor(Date.now() / period) + 1) * period;
        await r.advanceClock(boundary - Date.now() - 20_000);
        const prepare = async (expiresAt) => {
            const owner = await enrolled(r, 'rollover-author'), receiver = await enrolled(r, 'rollover-receiver');
            const identity = await signReplyDevice(r, receiver, 'rollover-receiver');
            const slot = replySlot(), id = randomUUID();
            assert.equal((await call(r, `${replyPath}/open`, { slot, expiresAt }, owner.accessToken, 'PUT')).status, 200);
            const body = { owner: owner.userID, slot, id, packet: replyPacket(), expiresAt };
            const signed = await signBackgroundSubmission(body, receiver, identity, origin,
                'submitBackgroundContactInvitationAcceptance');
            return { signed, key: identity.relayKey, id };
        };
        const original = await prepare(boundary + 60_000);
        const queued = await sealInvitationSubmission(original.signed, original.key);
        await r.advanceClock(40_000);
        const received = await call(r, endpoint, { sealed: queued });
        assert.equal(received.status, 200);
        assert.equal((await received.json()).id, original.id);

        await r.advanceClock(period);
        const ready = await prepare(boundary + period + 60_000);
        const encryptedForExpiredKey = await sealInvitationSubmission(ready.signed, original.key);
        assert.equal((await call(r, endpoint, { sealed: encryptedForExpiredKey })).status, 401);
        const encryptedForCurrentKey = await sealInvitationSubmission(ready.signed, ready.key);
        assert.equal((await call(r, endpoint, { sealed: encryptedForCurrentKey })).status, 200);
    } finally { await r.dispose(); }
});

test('the encrypted contact acceptance limits work before reading caller identity', async () => {
    const r = await makeRuntime({ ...options, INVITATION_RELAY_KEY_SEED: randomBytes(32).toString('base64url') }, { apiLimit: 1 });
    try {
        const endpoint = `${replyPath}/background-acceptance`;
        assert.equal((await call(r, endpoint, {})).status, 400);
        assert.equal((await call(r, endpoint, {})).status, 429);
    } finally { await r.dispose(); }
});

test('a signed contact invitation admits an offline reply before its author opens a mailbox', async () => {
    const issuer = await generateKeyPair('ES256', { extractable: true });
    const r = await makeRuntime({ ...options, NOTIFICATIONS_ENABLED: 'false',
        DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(issuer.privateKey)) }, { appleKeys: [publicKey], trackReplyStorage: true });
    try {
        const a = await enrolled(r, 'contact-author'), otherA = await enrolled(r, 'contact-author');
        const b = await enrolled(r, 'contact-recipient'), otherB = await enrolled(r, 'contact-recipient');
        const memberID = 'contact-author';
        const author = await signReplyDevice(r, a, memberID);
        const slot = replySlot(), expiresAt = Date.now() + 60_000;
        const permit = async (targetSlot, expiry = expiresAt, origin = 'https://worker.test') => ({
            expiresAt: expiry, deviceID: a.deviceID, sessionBinding: author.sessionBinding,
            proof: await author.proof('openContactInvitationReply', JSON.stringify([origin, author.sessionBinding, targetSlot, expiry]))
        });
        const first = { id: randomUUID(), packet: replyPacket() };
        const write = (action, body, user) => call(r, replyPath + action, body, user?.accessToken, 'PUT');
        const inbox = (user, mailbox = slot) => call(r, `${replyPath}/inbox`, { slot: mailbox }, user.accessToken);
        const accept = (changes = {}, user = b) => write('/acceptance', { owner: a.userID, slot, ...first, ...changes }, user);
        const admission = await permit(slot);
        assert.equal((await inbox(a)).status, 404);
        assert.equal((await accept()).status, 404);
        assert.equal((await accept({ admission }, {})).status, 401);
        assert.equal((await accept({ slot: replySlot(), admission })).status, 401);
        assert.equal((await accept({ admission: { ...admission, expiresAt: expiresAt + 1 } })).status, 401);
        assert.equal((await accept({ admission: { ...admission, deviceID: otherA.deviceID } })).status, 401);
        assert.equal((await accept({ owner: b.userID, admission })).status, 401);
        assert.equal((await accept({ admission: await permit(slot, expiresAt, 'https://other.test') })).status, 401);
        assert.equal((await accept({ admission: await permit(slot, Date.now() - 1) })).status, 400);
        // The account has a public route from enrollment, but the author never opened this mailbox.
        const [stored, retried] = await Promise.all([accept({ admission }), accept({ admission })]);
        assert.deepEqual([stored.status, retried.status], [200, 200]);
        const accounts = await r.getDurableObjectNamespace('USER_ACCOUNT');
        const account = accounts.get(accounts.idFromString(a.accessToken.split('.')[1]));
        const before = JSON.parse(await account.replyStorageState());
        assert.equal(before.alarm, expiresAt);
        assert.equal((await accept({ admission, packet: replyPacket() })).status, 200);
        assert.deepEqual(JSON.parse(await account.replyStorageState()), before);
        assert.equal((await inbox(otherA)).status, 404);
        assert.equal((await write('/open', { slot, expiresAt }, otherA)).status, 409);
        assert.deepEqual(await (await inbox(a)).json(), { acceptances: [first] });
        const confirmation = { id: first.id, packet: replyPacket() };
        assert.equal((await write('/acknowledgement', { slot, ...confirmation }, a)).status, 200);
        const lookup = { owner: a.userID, slot, id: first.id };
        assert.equal((await call(r, `${replyPath}/receipt`, lookup, otherB.accessToken)).status, 404);
        assert.deepEqual(await (await call(r, `${replyPath}/receipt`, lookup, b.accessToken)).json(), { receipt: confirmation });

        const unopenedSlot = replySlot(), stale = await permit(unopenedSlot);
        const renewed = await signIn(r, await challenge(r, a.deviceID), { sub: memberID });
        assert.equal(renewed.status, 200);
        assert.equal((await accept({ slot: unopenedSlot, admission: stale })).status, 401);
        assert.equal((await inbox(await renewed.json(), unopenedSlot)).status, 404);
    } finally { await r.dispose(); }
});

test('opening the same ordinary reply mailbox avoids writes and repairs missing expiry alarms', async () => {
    const r = await makeRuntime(options, { appleKeys: [publicKey], trackReplyStorage: true });
    try {
        const a = await enrolled(r, 'reopened-mailbox-author');
        const accountID = a.accessToken.split('.')[1];
        const accounts = await r.getDurableObjectNamespace('USER_ACCOUNT');
        const account = accounts.get(accounts.idFromString(accountID));
        const indexes = await r.getDurableObjectNamespace('NOTIFICATION_INDEX');
        const route = indexes.get(indexes.idFromName(`user:${a.userID}`));
        const first = { slot: replySlot(), expiresAt: Date.now() + 60_000 };
        const later = { slot: replySlot(), expiresAt: first.expiresAt + 30_000 };
        const open = async item => assert.equal((await call(r, `${replyPath}/open`, item, a.accessToken, 'PUT')).status, 200);
        const state = async stub => JSON.parse(await stub.replyStorageState());
        await open(first);
        const accountFirst = await state(account);
        const routeFirst = await state(route);
        assert.equal(accountFirst.alarm, first.expiresAt);
        assert.ok(routeFirst.alarm >= first.expiresAt);

        await open(first);
        assert.deepEqual(await state(account), accountFirst);
        assert.deepEqual(await state(route), routeFirst);

        const laterRouteExpiry = Math.max(routeFirst.alarm, later.expiresAt) + 1_000;
        // Extend the public route through its owner. The account already has an earlier alarm.
        await route.bind({ accountID, userID: a.userID, expiresAt: laterRouteExpiry });
        const extendedRoute = await state(route);
        assert.deepEqual(extendedRoute, { put: routeFirst.put + 1, setAlarm: routeFirst.setAlarm + 1, alarm: laterRouteExpiry });
        await open(later);
        const accountLater = await state(account);
        assert.deepEqual(accountLater, { ...accountFirst, put: accountFirst.put + 1 });
        assert.deepEqual(await state(route), extendedRoute);

        await Promise.all([account.clearReplyAlarm(), route.clearReplyAlarm()]);
        await open(later);
        assert.deepEqual(await state(account), { ...accountLater, setAlarm: accountLater.setAlarm + 1 });
        assert.deepEqual(await state(route), { ...extendedRoute, setAlarm: extendedRoute.setAlarm + 1 });
    } finally { await r.dispose(); }
});

test('ordinary group replies persist while peers take turns online and leave the active call alone', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-replies-'));
    const local = () => makeRuntime({ ...options, NOTIFICATIONS_ENABLED: 'false' }, { appleKeys: [publicKey], storageDirectory });
    let r = await local();
    try {
        const a = await enrolled(r, 'reply-author'), anotherA = await enrolled(r, 'reply-author');
        const b = await enrolled(r, 'reply-recipient'), anotherB = await enrolled(r, 'reply-recipient');
        const c = await enrolled(r, 'second-recipient');
        const slot = replySlot(), expiresAt = Date.now() + 60_000;
        const write = (action, body, device = a) => call(r, replyPath + action, body, device.accessToken, 'PUT');
        const read = (action, body, device = a) => call(r, replyPath + action, body, device.accessToken);
        const first = { id: randomUUID(), packet: replyPacket() };
        const second = { id: randomUUID(), packet: replyPacket() };
        const destination = { owner: a.userID, slot };
        const status = async (response, code) => assert.equal((await response).status, code);

        provider.requests = [];
        const started = await call(r, `/api/rooms/${room}/join`, { participantId: a.deviceID, offer }, a.accessToken);
        assert.equal(started.status, 200);
        const active = (await started.json()).sessionId;
        await status(write('/acceptance', { ...destination, ...first }, b), 404);
        await status(write('/open', { slot, expiresAt }), 200);
        await status(write('/open', { slot, expiresAt }, anotherA), 409);
        await status(write('/acceptance', { ...destination, slot: replySlot(), ...first }, b), 404);
        await status(write('/acceptance', { ...destination, ...first }, b), 200);
        await status(write('/acceptance', { ...destination, ...first }, anotherB), 409);
        await status(write('/acceptance', { ...destination, ...first, packet: replyPacket() }, b), 200);
        await status(write('/acceptance', { ...destination, ...second }, c), 200);
        await status(read('/receipt', { ...destination, id: first.id }, b), 404);
        await status(write('/acknowledgement', { slot, id: randomUUID(), packet: replyPacket() }), 404);
        await status(call(r, `/api/rooms/${room}/sessions/${active}/renew`, {}, a.accessToken), 200);
        assert.equal(provider.requests.filter(p => p.url.endsWith('/sessions/new')).length, 1);

        await r.dispose();
        r = await local();
        await status(read('/inbox', { slot }, anotherA), 404);
        const inbox = await read('/inbox', { slot });
        assert.equal(inbox.status, 200);
        assert.deepEqual((await inbox.json()).acceptances.sort((l, r) => l.id.localeCompare(r.id)), [first, second].sort((l, r) => l.id.localeCompare(r.id)));
        const confirmation = { id: first.id, packet: replyPacket() };
        await status(write('/acknowledgement', { slot, ...confirmation }, anotherA), 404);
        await status(write('/acknowledgement', { slot, ...confirmation }), 200);
        await status(write('/acknowledgement', { slot, ...confirmation, packet: replyPacket() }), 200);
        assert.deepEqual(await (await read('/inbox', { slot })).json(), { acceptances: [second] });

        await r.dispose();
        r = await local();
        const lookup = { ...destination, id: first.id };
        await status(read('/receipt', lookup, anotherB), 404);
        await status(read('/receipt', lookup, c), 404);
        await status(read('/receipt', { ...lookup, owner: c.userID }, b), 404);
        assert.deepEqual(await (await read('/receipt', lookup, b)).json(), { receipt: confirmation });
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('ordinary group reply mailboxes bound storage, reject expired credentials and clear with account deletion', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-group-reply-expiry-'));
    const local = (clockOffsetMs = 0) => makeRuntime({ ...options, CLOUDFLARE_SFU_APP_ID: '', CLOUDFLARE_SFU_APP_SECRET: '' },
        { appleKeys: [publicKey], storageDirectory, clockOffsetMs });
    let r = await local();
    try {
        const a = await enrolled(r, 'limited-author'), b = await enrolled(r, 'limited-recipient');
        const items = Array.from({ length: 33 }, () => ({ slot: replySlot(), expiresAt: Date.now() + 60_000 }));
        const open = (item, user = a) => call(r, `${replyPath}/open`, item, user.accessToken, 'PUT');
        const inbox = (item, user = a) => call(r, `${replyPath}/inbox`, { slot: item.slot }, user.accessToken);
        const accept = (packet, slot = items[0].slot, user = b) => call(r, `${replyPath}/acceptance`,
            { owner: a.userID, slot, id: randomUUID(), packet }, user.accessToken, 'PUT');
        assert.equal((await open(items[0], {})).status, 401);
        assert.equal((await open({ ...items[0], expiresAt: Date.now() + 8 * 86_400_000 })).status, 400);
        assert.equal((await open({ ...items[0], slot: 'too-short' })).status, 400);
        const opened = await Promise.all(items.slice(0, 32).map(item => open(item)));
        assert.deepEqual(new Set(opened.map(response => response.status)), new Set([200]));
        assert.equal((await open(items[32])).status, 429);
        assert.equal((await open(items[0])).status, 200);
        assert.equal((await accept('A'.repeat(12 * 1024 + 4))).status, 400);
        assert.equal((await accept(`${replyPacket()}\n`)).status, 400);
        assert.equal((await accept(replyPacket())).status, 200);
        assert.equal((await accept(replyPacket())).status, 409);
        const recipients = [];
        for (let i = 0; i < 8; i++) recipients.push(await enrolled(r, `bounded-reply-${i}`));
        const simultaneous = await Promise.all(recipients.map(user => accept(replyPacket(), items[0].slot, user)));
        assert.deepEqual(simultaneous.map(response => response.status).sort(), [200, 200, 200, 200, 200, 200, 200, 429]);

        await r.dispose();
        r = await local(61_000);
        assert.equal((await inbox(items[0])).status, 404);
        assert.equal((await open(items[0])).status, 400);
        const live = { ...items[32], expiresAt: Date.now() + 120_000 };
        assert.equal((await open(live)).status, 200);
        assert.equal((await accept(replyPacket(), live.slot)).status, 200);
        assert.equal((await call(r, '/api/auth/session', undefined, b.accessToken, 'DELETE')).status, 200);
        assert.equal((await accept(replyPacket(), live.slot)).status, 401);
        assert.equal((await call(r, '/api/auth/account', undefined, a.accessToken, 'DELETE')).status, 200);
        assert.equal((await inbox(live)).status, 401);
        assert.equal((await accept(replyPacket(), live.slot, recipients[0])).status, 404);
        const replacement = await enrolled(r, 'limited-author');
        assert.notEqual(replacement.userID, a.userID);
        assert.equal((await inbox(live, replacement)).status, 404);
        assert.equal((await open(live, replacement)).status, 200);
        assert.deepEqual(await (await inbox(live, replacement)).json(), { acceptances: [] });
    } finally { await r.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('one public account reserves one connection across rooms, devices and forged identity headers', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const accounts = [await enrolled(runtime), await enrolled(runtime)];
        const rooms = [room, 'b'.repeat(64)];
        provider.requests = [];
        const responses = await Promise.all(accounts.map((account, i) => call(runtime, `/api/rooms/${rooms[i]}/join`,
            { participantId: account.deviceID, offer }, account.accessToken)));
        assert.deepEqual(responses.map(r => r.status).sort(), [200, 409]);
        const winner = responses.findIndex(r => r.status === 200), loser = 1 - winner;
        const media = await responses[winner].json();
        assert.equal((await responses[loser].json()).code, 'account_in_use');
        assert.equal(provider.requests.filter(r => r.url.endsWith('/sessions/new')).length, 1);
        const forged = await runtime.dispatchFetch(`https://worker.test/api/rooms/${'c'.repeat(64)}/join`, {
            method: 'POST', headers: { Authorization: `Bearer ${accounts[winner].accessToken}`, 'Content-Type': 'application/json',
                'X-User': 'd'.repeat(64), 'X-Owner': 'someone-else' }, body: JSON.stringify({ participantId: 'new-peer', offer })
        });
        assert.equal(forged.status, 409);
        assert.equal((await forged.json()).code, 'account_in_use');
        const path = `/api/rooms/${rooms[winner]}/sessions/${media.sessionId}`;
        assert.equal((await call(runtime, `${path}/renew`, {}, accounts[winner].accessToken)).status, 200);
        const independent = await enrolled(runtime, 'other-person');
        assert.equal((await call(runtime, `/api/rooms/${rooms[winner]}/join`, { participantId: independent.deviceID, offer }, independent.accessToken)).status, 200);
        assert.equal((await call(runtime, path, undefined, accounts[winner].accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${rooms[loser]}/join`, { participantId: accounts[loser].deviceID, offer }, accounts[loser].accessToken)).status, 200);
    } finally { await runtime.dispose(); }
});

const turnOptions = { ...options, TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-key', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
test('TURN preparation owns the same account slot as join and renewal, and cancellation frees it', async () => {
    const runtime = await makeRuntime(turnOptions, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        const ice = `/api/rooms/${room}/ice/${one.deviceID}`;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        const count = provider.requests.length;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 409);
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 200);
        const nextIce = `/api/rooms/${room}/ice/${two.deviceID}`;
        assert.equal((await call(runtime, nextIce, { leaseID: 'second' }, two.accessToken)).status, 200);
        const joined = await call(runtime, `/api/rooms/${room}/join`, { participantId: two.deviceID, offer, iceLeaseID: 'second' }, two.accessToken);
        assert.equal(joined.status, 200);
        const media = await joined.json();
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${media.sessionId}/renew`, {}, two.accessToken)).status, 200);
    } finally { await runtime.dispose(); }
});

test('public account connection reservations survive restart and expire with their lease', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-connection-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        const target = `/api/rooms/${'b'.repeat(64)}/join`, body = { participantId: two.deviceID, offer };
        assert.equal((await call(runtime, target, body, two.accessToken)).status, 409);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 601000 });
        assert.equal((await call(runtime, target, body, two.accessToken)).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('failed TURN cleanup retains the account slot until cleanup succeeds', async () => {
    const runtime = await makeRuntime(turnOptions, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        const ice = `/api/rooms/${room}/ice/${one.deviceID}`;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken)).status, 200);
        provider.revokeFails = true;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 502);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 409);
        provider.revokeFails = false;
        assert.equal((await call(runtime, ice, { leaseID: 'first' }, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/ice/${two.deviceID}`, { leaseID: 'second' }, two.accessToken)).status, 200);
    } finally { provider.revokeFails = false; await runtime.dispose(); }
});


test('a failed SFU setup keeps its account slot until the room alarm completes cleanup', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        provider.establishFails = true;
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 502);
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/join`, { participantId: two.deviceID, offer }, two.accessToken)).status, 409);
        provider.establishFails = false;
        let active;
        for (let i = 0; i < 60; i++) {
            active = (await (await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).json()).activeSessions;
            if (active === 0) break;
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        assert.equal(active, 0, 'The room alarm must release the failed session reservation');
        assert.equal((await call(runtime, `/api/rooms/${'b'.repeat(64)}/join`, { participantId: two.deviceID, offer }, two.accessToken)).status, 200);
    } finally { provider.establishFails = false; await runtime.dispose(); }
});


test('account deletion removes every device of only the authenticated account and retries safely', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime), other = await enrolled(runtime, 'different-person');
        const oldAttempt = await challenge(runtime);
        const responses = await Promise.all([0, 1].map(() => call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')));
        assert.deepEqual(responses.map(r => r.status), [200, 200]);
        assert.deepEqual(await responses[0].json(), { deleted: true, appleAuthorizationRevoked: false });
        for (const credential of [one, two]) assert.equal((await call(runtime, '/api/auth/session', undefined, credential.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, other.accessToken, 'GET')).status, 200);
        assert.equal((await signIn(runtime, oldAttempt)).status, 401, 'A proof issued before deletion must not recreate device access');
        const replacement = await enrolled(runtime);
        assert.notEqual(replacement.userID, one.userID, 'Deletion must retire the previous public identity');
        const replay = await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE');
        assert.equal(replay.status, 200);
        assert.deepEqual(await replay.json(), { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true });
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200, 'A repeated old deletion must not delete new registrations');
        assert.equal((await call(runtime, '/api/auth/account', undefined, two.accessToken, 'DELETE')).status, 401);
    } finally { await runtime.dispose(); }
});

test('account deletion receipt survives restart, expires, and still works with enrollment disabled', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-account-deletion-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'GET')).status, 405);
        assert.equal((await call(runtime, '/api/auth/account', undefined, 'invalid', 'DELETE')).status, 401);
        await runtime.dispose();
        runtime = await makeRuntime({ ...options, APPLE_AUTH_ENABLED: 'false', SERVICE_ENABLED: 'false' }, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        const replacement = await enrolled(runtime);
        assert.notEqual(replacement.userID, one.userID, 'Deletion must retire the previous public identity');
        await runtime.dispose();
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 86401000 });
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


test('public identity survives all-device sign-out and expiry, but not account deletion', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-public-identity-'));
    let runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'DELETE')).status, 200);
        const again = await enrolled(runtime);
        assert.equal(again.userID, one.userID);
        await runtime.dispose();
        const offset = 31 * 86400000;
        runtime = await makeRuntime(options, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: offset });
        assert.equal((await call(runtime, '/api/auth/session', undefined, again.accessToken, 'GET')).status, 401);
        const now = Math.floor((Date.now() + offset) / 1000);
        const restoredResponse = await signIn(runtime, await challenge(runtime), { iat: now, exp: now + 300 });
        assert.equal(restoredResponse.status, 200);
        const restored = await restoredResponse.json();
        assert.equal(restored.userID, one.userID, 'Credential expiry is not account deletion');
        assert.equal((await call(runtime, '/api/auth/account', undefined, restored.accessToken, 'DELETE')).status, 200);
        const attempts = await Promise.all([challenge(runtime), challenge(runtime)]);
        const replacements = await Promise.all(attempts.map(attempt => signIn(runtime, attempt, { iat: now, exp: now + 300 })));
        assert.ok(replacements.every(response => response.status === 200));
        const identities = await Promise.all(replacements.map(response => response.json()));
        assert.notEqual(identities[0].userID, one.userID);
        assert.equal(identities[0].userID, identities[1].userID, 'Concurrent enrollment must share the new identity');
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('re-enrollment waits until failed SFU deletion cleanup completes', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: one.deviceID, offer }, one.accessToken)).status, 200);
        provider.upstreamFails = true;
        const deletion = await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE');
        assert.equal(deletion.status, 200);
        assert.equal((await deletion.json()).mediaCleanupPending, true);
        const count = provider.requests.length;
        const registration = await signIn(runtime, await challenge(runtime));
        assert.equal(registration.status, 409);
        assert.equal((await registration.json()).code, 'deletion_pending');
        assert.equal(provider.requests.length, count);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'GET')).status, 401);
    } finally { provider.upstreamFails = false; await runtime.dispose(); }
});


test('device identity certificate binds only authenticated user and device to a public signing key', async () => {
    const signer = await generateKeyPair('ES256', { extractable: true });
    const signingJWK = await exportJWK(signer.privateKey);
    const deviceKeys = await generateKeyPair('ES256', { extractable: true });
    const deviceKey = Buffer.from(await crypto.subtle.exportKey('raw', deviceKeys.publicKey)).toString('base64url');
    const runtime = await makeRuntime({ ...options, DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(signingJWK) }, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime);
        const providerCount = provider.requests.length;
        const response = await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey, userID: 'forged-user', deviceID: randomUUID() }, one.accessToken);
        assert.equal(response.status, 200);
        const result = await response.json();
        assert.equal(result.issuerKey, Buffer.from(await crypto.subtle.exportKey('raw', signer.publicKey)).toString('base64url'));
        const { payload, protectedHeader } = await jwtVerify(result.certificate, signer.publicKey, {
            issuer: 'https://worker.test', audience: 'rideintercom-peer', algorithms: ['ES256'], typ: 'rideintercom-device+jwt'
        });
        assert.deepEqual(Object.keys(protectedHeader).sort(), ['alg', 'typ']);
        assert.equal(payload.sub, one.userID); assert.equal(payload.deviceID, one.deviceID);
        assert.equal(payload.memberID, 'member-fixture'); assert.equal(payload.deviceKey, deviceKey);
        assert.equal(payload.invitationRelayKey, undefined);
        assert.ok(payload.exp * 1000 <= one.expiresAt && payload.exp > payload.iat);
        const serialized = JSON.stringify(result);
        for (const secret of [one.accessToken, one.accessToken.split('.')[1], signingJWK.d, 'apple-private-subject', 'private@example.invalid']) assert.ok(!serialized.includes(secret));
        assert.equal(provider.requests.length, providerCount);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey }, one.accessToken)).status, 401);
        const replacement = await enrolled(runtime);
        const renewed = await call(runtime, '/api/auth/identity', { memberID: 'member-fixture', deviceKey }, replacement.accessToken);
        assert.equal(renewed.status, 200);
        const next = await jwtVerify((await renewed.json()).certificate, signer.publicKey);
        assert.notEqual(next.payload.sub, payload.sub);
    } finally { await runtime.dispose(); }
});

test('device certificates publish only the current origin-bound invitation relay key', async () => {
    const signer = await generateKeyPair('ES256', { extractable: true });
    const device = await generateKeyPair('ES256');
    const deviceKey = Buffer.from(await crypto.subtle.exportKey('raw', device.publicKey)).toString('base64url');
    const seed = randomBytes(32).toString('base64url');
    const runtime = await makeRuntime({ ...options, DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signer.privateKey)),
        INVITATION_RELAY_KEY_SEED: seed }, { appleKeys: [publicKey], adjustableClock: true });
    try {
        const period = 30 * 86400;
        const nextPeriodAt = (Math.floor(Date.now() / 1000 / period) + 1) * period;
        await runtime.advanceClock(nextPeriodAt * 1000 - Date.now() - 20_000);
        const user = await enrolled(runtime);
        const read = async (origin = 'https://worker.test') => {
            const response = await runtime.dispatchFetch(`${origin}/api/auth/identity`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.10', Authorization: `Bearer ${user.accessToken}` },
                body: JSON.stringify({ memberID: 'key-fixture', deviceKey })
            });
            assert.equal(response.status, 200);
            const result = await response.json();
            const { payload } = await jwtVerify(result.certificate, signer.publicKey, {
                issuer: origin, audience: 'rideintercom-peer', algorithms: ['ES256']
            });
            const key = payload.invitationRelayKey;
            assert.ok(key, 'The verified certificate must carry a relay key');
            assert.deepEqual(Object.keys(key).sort(), ['expiresAt', 'kid', 'x']);
            assert.equal(Buffer.from(key.x, 'base64url').length, 32);
            assert.equal(JSON.stringify(key).includes(seed), false);
            assert.ok(key.expiresAt >= payload.exp);
            return key;
        };
        const first = await read();
        assert.equal(first.kid, `v1-${nextPeriodAt / period - 1}`);
        assert.equal(first.expiresAt, nextPeriodAt + period);
        const material = hkdfSync('sha256', Buffer.from(seed, 'base64url'), 'rideintercom.invitation-relay-key.v1',
            JSON.stringify(['https://worker.test', nextPeriodAt / period - 1]), 32);
        const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b656e04220420', 'hex'), Buffer.from(material)]);
        const expected = createPublicKey(createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' })).export({ format: 'jwk' });
        assert.equal(first.x === expected.x, true, 'The advertised coordinate must match the derived private key');
        assert.deepEqual(await read(), first);
        const preview = await read('https://preview.worker.test');
        assert.equal(preview.kid, first.kid);
        assert.equal(preview.x === first.x, false);

        await runtime.advanceClock(40_000);
        const next = await read();
        assert.equal(next.kid, `v1-${nextPeriodAt / period}`);
        assert.equal(next.expiresAt, first.expiresAt + period);
        assert.equal(next.x === first.x, false);
    } finally { await runtime.dispose(); }
});

test('device identity issuance rejects invalid keys, identifiers and unconfigured signing', async () => {
    const signer = await generateKeyPair('ES256', { extractable: true });
    const deviceKey = Buffer.from(await crypto.subtle.exportKey('raw', signer.publicKey)).toString('base64url');
    const runtime = await makeRuntime({ ...options, DEVICE_IDENTITY_SIGNING_KEY: JSON.stringify(await exportJWK(signer.privateKey)),
        INVITATION_RELAY_KEY_SEED: 'invalid' }, { appleKeys: [publicKey] });
    const disabled = await makeRuntime(options, { appleKeys: [publicKey] });
    try {
        const one = await enrolled(runtime), other = await enrolled(disabled);
        const valid = { memberID: 'member-fixture', deviceKey };
        assert.equal((await call(disabled, '/api/auth/identity', valid, other.accessToken)).status, 503);
        assert.equal((await call(runtime, '/api/auth/identity', valid, 'invalid')).status, 401);
        assert.equal((await call(runtime, '/api/auth/identity', undefined, one.accessToken, 'GET')).status, 405);
        for (const body of [{ ...valid, deviceKey: 'invalid' }, { ...valid, deviceKey: Buffer.alloc(65).toString('base64url') },
            { ...valid, memberID: '' }, { ...valid, memberID: 'invite-pending-test' }, { ...valid, memberID: 'x'.repeat(64) }]) {
            assert.equal((await call(runtime, '/api/auth/identity', body, one.accessToken)).status, 400);
        }
        const issued = await call(runtime, '/api/auth/identity', valid, one.accessToken);
        assert.equal(issued.status, 200);
        const { payload } = await jwtVerify((await issued.json()).certificate, signer.publicKey);
        assert.equal(payload.invitationRelayKey, undefined);
    } finally { await runtime.dispose(); await disabled.dispose(); }
});

test('deletion verifies Apple code ownership and revokes before reporting completion', async () => {
    const clientSecrets = [], clientSecretPayloads = [];
    let appleIdentityToken;
    const runtime = await makeRuntime({ ...options, ...appleClientConfiguration }, { appleKeys: [publicKey], appleAuthorization: async (path, form) => {
        assert.equal(form.get('client_id'), audience);
        const clientSecret = form.get('client_secret');
        assert.ok(clientSecret);
        const { payload, protectedHeader } = await jwtVerify(clientSecret, appleClientKeys.publicKey, {
            algorithms: ['ES256'], issuer: appleClientConfiguration.APPLE_TEAM_ID,
            audience: 'https://appleid.apple.com', subject: audience
        });
        assert.equal(protectedHeader.kid, appleClientConfiguration.APPLE_SIGN_IN_KEY_ID);
        assert.equal(payload.exp - payload.iat, 300);
        clientSecrets.push(clientSecret);
        clientSecretPayloads.push(payload);
        if (path.endsWith('/token')) {
            assert.equal(form.get('grant_type'), 'authorization_code');
            assert.ok(['delete-code', 'later-delete-code'].includes(form.get('code')));
            return Response.json({ refresh_token: 'delete-refresh', id_token: appleIdentityToken });
        }
        assert.equal(path, '/auth/revoke'); assert.equal(form.get('token'), 'delete-refresh');
        assert.equal(form.get('token_type_hint'), 'refresh_token'); revoked++;
        return new Response(null, { status: 200 });
    }, adjustableClock: true });
    let deletionProof, revoked = 0;
    try {
        const user = await enrolled(runtime);
        deletionProof = await challenge(runtime, user.deviceID);
        appleIdentityToken = await proof(deletionProof);
        const body = { challengeID: deletionProof.challengeID, identityToken: appleIdentityToken, authorizationCode: 'delete-code' };
        const response = await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal(revoked, 1);
        assert.equal(clientSecrets.length, 2);
        assert.equal(clientSecrets[0], clientSecrets[1], 'A valid generated client secret should be reused within one isolate');
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        const replacement = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE')).status, 200);
        assert.equal(revoked, 1, 'Old deletion must not revoke a newly registered Apple authorization');
        assert.equal((await call(runtime, '/api/auth/session', undefined, replacement.accessToken, 'GET')).status, 200);
        await runtime.advanceClock(301000);
        deletionProof = await challenge(runtime, replacement.deviceID);
        const shiftedNow = Math.floor(Date.now() / 1000) + 301;
        appleIdentityToken = await proof(deletionProof, { iat: shiftedNow, exp: shiftedNow + 300 });
        const second = await call(runtime, '/api/auth/account', {
            challengeID: deletionProof.challengeID, identityToken: appleIdentityToken, authorizationCode: 'later-delete-code'
        }, replacement.accessToken, 'DELETE');
        assert.equal(second.status, 200);
        assert.equal(revoked, 2);
        assert.equal(clientSecrets.length, 4);
        assert.equal(clientSecrets[2], clientSecrets[3], 'The replacement client secret should cover exchange and revocation');
        assert.notEqual(clientSecrets[0], clientSecrets[2]);
        assert.ok(clientSecretPayloads[0].exp < clientSecretPayloads[2].iat, 'A new client secret must be generated after expiry');
    } finally { await runtime.dispose(); }
});

test('Apple authorization requires every long-lived signing credential', async () => {
    for (const missing of Object.keys(appleClientConfiguration)) {
        const configuration = { ...appleClientConfiguration };
        delete configuration[missing];
        let requests = 0;
        const runtime = await makeRuntime({ ...options, ...configuration }, {
            appleKeys: [publicKey], appleAuthorization: async () => { requests++; return new Response(null, { status: 500 }); }
        });
        try {
            const user = await enrolled(runtime);
            const response = await call(runtime, '/api/auth/account', { proof: 'present' }, user.accessToken, 'DELETE');
            assert.equal(response.status, 503, missing);
            assert.equal(requests, 0, missing);
        } finally { await runtime.dispose(); }
    }
});

test('Apple revocation failure persists and blocks re-enrollment until retry succeeds', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-apple-revoke-'));
    let attempt, fail = true, tokens = 0, revocations = 0;
    const appleAuthorization = async path => {
        if (path.endsWith('/token')) { tokens++; return Response.json({ refresh_token: 'retry-token', id_token: await proof(attempt) }); }
        revocations++; return new Response(null, { status: fail ? 503 : 200 });
    };
    const config = { ...options, ...appleClientConfiguration };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const response = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: false, appleRevocationPending: true });
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        for (let n = 0; n < 3; n++) assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(revocations, 1); assert.equal(tokens, 1);
        const blocked = await signIn(runtime, await challenge(runtime));
        assert.equal(blocked.status, 409); assert.equal((await blocked.json()).code, 'deletion_pending');
        await runtime.dispose(); fail = false;
        runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization, clockOffsetMs: 61000 });
        const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(retried.status, 200); assert.deepEqual(await retried.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal(tokens, 1, 'Consumed authorization code is not exchanged again');
        assert.equal(revocations, 2);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion rejects another account, token subject, redirects and oversized Apple responses', async () => {
    let attempt, mode = 'other-subject', tokens = 0, revocations = 0;
    const runtime = await makeRuntime({ ...options, ...appleClientConfiguration }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) { revocations++; return new Response(null, { status: 200 }); }
        tokens++;
        if (mode === 'redirect') return new Response(null, { status: 302, headers: { Location: 'https://other.invalid/token' } });
        if (mode === 'large') return new Response('x'.repeat(32769), { status: 200 });
        return Response.json({ refresh_token: 'other-token', id_token: await proof(attempt, { sub: 'other-person' }) });
    } });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const wrong = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt, { sub: 'other-person' }), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        assert.equal(wrong.status, 401); assert.equal(tokens, 0);
        for (mode of ['other-subject', 'redirect', 'large']) {
            attempt = await challenge(runtime, user.deviceID);
            const response = await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
                identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
            assert.equal(response.status, 503);
            assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 200);
        }
        assert.equal(revocations, 0);
        const plain = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.deepEqual(await plain.json(), { deleted: true, appleAuthorizationRevoked: false });
    } finally { await runtime.dispose(); }
});

test('concurrent deletion preparation cannot mint a second Apple grant', async () => {
    let attempt, tokens = 0, entered, release;
    const waiting = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    const runtime = await makeRuntime({ ...options, ...appleClientConfiguration }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        tokens++; entered(); await gate;
        return Response.json({ refresh_token: 'once-token', id_token: await proof(attempt) });
    } });
    try {
        const user = await enrolled(runtime);
        attempt = await challenge(runtime, user.deviceID);
        const pending = call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE');
        await waiting;
        const other = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', { challengeID: other.challengeID,
            identityToken: await proof(other), authorizationCode: 'second-code' }, user.accessToken, 'DELETE')).status, 503);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 409);
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 503);
        release(); assert.equal((await pending).status, 200); assert.equal(tokens, 1);
    } finally { release(); await runtime.dispose(); }
});

test('pending Apple revocation outlives receipt expiry and retries remain bounded after exhaustion', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-apple-retry-limit-'));
    let attempt, revocations = 0, user;
    const config = { ...options, ...appleClientConfiguration };
    const appleAuthorization = async path => {
        if (path.endsWith('/token')) return Response.json({ refresh_token: 'pending-token', id_token: await proof(attempt) });
        revocations++; return new Response(null, { status: 503 });
    };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization });
    try {
        user = await enrolled(runtime); attempt = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', { challengeID: attempt.challengeID,
            identityToken: await proof(attempt), authorizationCode: 'code' }, user.accessToken, 'DELETE')).status, 200);
        for (const offset of [61000, 362000, 2163000, 9364000, 30965000, 86401000]) {
            await runtime.dispose();
            runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], appleAuthorization, clockOffsetMs: offset });
            const result = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(result.status, 200); assert.equal((await result.json()).appleRevocationPending, true);
            const before = revocations;
            for (let n = 0; n < 3; n++) await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(revocations, before, 'Manual retries cannot bypass the minimum interval');
        }
        assert.equal(revocations, 7);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

async function recoveryProof(attempt, changes = {}) {
    return proof(attempt, { iat: Math.floor(attempt.issuedAt / 1000), exp: Math.floor(attempt.expiresAt / 1000), ...changes });
}
async function recoveryBody(attempt, userID, changes = {}) {
    return { challengeID: attempt.challengeID, identityToken: await recoveryProof(attempt, changes),
        authorizationCode: 'recovery-code', expectedUserID: userID };
}

test('deletion recovery authorizes revoked credentials only with same Apple subject and target', async () => {
    let attempt, exchanges = 0;
    const runtime = await makeRuntime({ ...options, ...appleClientConfiguration }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        exchanges++; return Response.json({ refresh_token: 'recovered', id_token: await recoveryProof(attempt) });
    } });
    try {
        const user = await enrolled(runtime);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 401);
        attempt = await challenge(runtime, user.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID, { sub: 'another-person' }), user.accessToken, 'DELETE')).status, 401);
        assert.equal(exchanges, 0);
        const wrongDevice = await challenge(runtime);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(wrongDevice, user.userID), user.accessToken, 'DELETE')).status, 401);
        attempt = await challenge(runtime, user.deviceID);
        const missingTarget = await recoveryBody(attempt, user.userID); delete missingTarget.expectedUserID;
        assert.equal((await call(runtime, '/api/auth/account', missingTarget, user.accessToken, 'DELETE')).status, 401);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, '../other'), user.accessToken, 'DELETE')).status, 400);
        const body = await recoveryBody(attempt, user.userID);
        const response = await call(runtime, '/api/auth/account', body, user.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { deleted: true, appleAuthorizationRevoked: true });
        assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(exchanges, 1);
    } finally { await runtime.dispose(); }
});

test('deletion recovery survives credential expiry and later receipt expiry without registering an account', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-deletion-recovery-'));
    let attempt, exchanges = 0;
    const config = { ...options, ...appleClientConfiguration };
    const provider = { storageDirectory, appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 200 });
        exchanges++; return Response.json({ refresh_token: 'recovered', id_token: await recoveryProof(attempt) });
    } };
    let runtime = await makeRuntime(config, provider);
    try {
        const user = await enrolled(runtime);
        for (const days of [31, 33]) {
            await runtime.dispose(); runtime = await makeRuntime(config, { ...provider, clockOffsetMs: days * 86400000 });
            assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 401);
            attempt = await challenge(runtime, user.deviceID);
            const result = await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID), user.accessToken, 'DELETE');
            assert.equal(result.status, 200);
            assert.deepEqual(await result.json(), { deleted: true, appleAuthorizationRevoked: true });
            assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        }
        assert.equal(exchanges, 2);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion recovery preserves a newer public account and never cancels its Apple grant', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-deletion-newer-'));
    let exchanges = 0;
    const config = { ...options, ...appleClientConfiguration };
    const provider = { storageDirectory, appleKeys: [publicKey], appleAuthorization: async () => { exchanges++; return new Response(null, { status: 500 }); } };
    let runtime = await makeRuntime(config, provider);
    try {
        const user = await enrolled(runtime);
        await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        await runtime.dispose(); runtime = await makeRuntime(config, { ...provider, clockOffsetMs: 2 * 86400000 });
        const registration = await challenge(runtime);
        const newer = await (await call(runtime, '/api/auth/apple/session', { challengeID: registration.challengeID, identityToken: await recoveryProof(registration) })).json();
        assert.notEqual(newer.userID, user.userID);
        const attempt = await challenge(runtime, user.deviceID);
        const result = await call(runtime, '/api/auth/account', await recoveryBody(attempt, user.userID), user.accessToken, 'DELETE');
        assert.equal(result.status, 200);
        assert.deepEqual(await result.json(), { deleted: true, appleAuthorizationRevoked: false, newerAccountPreserved: true });
        assert.equal(exchanges, 0);
        assert.equal((await call(runtime, '/api/auth/session', undefined, newer.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('deletion recovery lets another authenticated owner device observe pending revocation without a new grant', async () => {
    let attempt, exchanges = 0;
    const runtime = await makeRuntime({ ...options, ...appleClientConfiguration }, { appleKeys: [publicKey], appleAuthorization: async path => {
        if (path.endsWith('/revoke')) return new Response(null, { status: 503 });
        exchanges++; return Response.json({ refresh_token: 'pending', id_token: await recoveryProof(attempt) });
    } });
    try {
        const one = await enrolled(runtime), two = await enrolled(runtime);
        attempt = await challenge(runtime, one.deviceID);
        assert.equal((await call(runtime, '/api/auth/account', await recoveryBody(attempt, one.userID), one.accessToken, 'DELETE')).status, 200);
        const other = await challenge(runtime, two.deviceID);
        const response = await call(runtime, '/api/auth/account', await recoveryBody(other, two.userID), two.accessToken, 'DELETE');
        assert.equal(response.status, 200);
        assert.equal((await response.json()).appleRevocationPending, true);
        for (const user of [one, two]) assert.equal((await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE')).status, 200);
        assert.equal(exchanges, 1);
    } finally { await runtime.dispose(); }
});

test('account deletion media cleanup stops only its owner and releases the account slot', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    let removedSocket, otherSocket;
    try {
        const user = await enrolled(runtime), other = await enrolled(runtime, 'another-caller');
        const join = async (credential, id) => (await call(runtime, `/api/rooms/${room}/join`, { participantId: id, offer }, credential.accessToken)).json();
        const a = await join(user, 'deleted-peer'), b = await join(other, 'remaining-peer');
        for (const [credential, session] of [[user, a], [other, b]]) {
            await call(runtime, `/api/rooms/${room}/sessions/${session.sessionId}/publish`, {}, credential.accessToken);
            const url = new URL(`/api/rooms/${room}/sessions/${session.sessionId}/signal`, await runtime.ready);
            url.protocol = 'ws:';
            // workerd can leave TCP half-open after sending Close. Bound the standard
            // client handshake wait; the assertions below still require its real Close frame.
            const socket = new WebSocket(url, { closeTimeout: 250, headers: { Authorization: `Bearer ${credential.accessToken}` } });
            await new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('error', reject); });
            if (credential === user) removedSocket = socket; else otherSocket = socket;
        }
        const closed = new Promise(resolve => removedSocket.addEventListener('close', resolve, { once: true }));
        const result = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(result.status, 200); assert.equal((await result.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(r => r.url.endsWith(`/sessions/${a.sessionId}/datachannels/close`)), 'Deleted media was not closed');
        let timer;
        const event = await Promise.race([closed, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('Deleted signaling stayed open')), 3000); })]).finally(() => clearTimeout(timer));
        assert.equal(event.code, 1000);
        assert.equal(event.reason, 'Account deleted');
        assert.equal(otherSocket.readyState, 1);
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${b.sessionId}/renew`, {}, other.accessToken)).status, 200);
        const fresh = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${'d'.repeat(64)}/join`, { participantId: 'new-account', offer }, fresh.accessToken)).status, 200);
        assert.ok(provider.requests.some(r => r.url.endsWith(`/sessions/${a.sessionId}/datachannels/close`)));
        assert.ok(!provider.requests.some(r => r.url.endsWith(`/sessions/${b.sessionId}/datachannels/close`)));
    } finally { removedSocket?.close(); otherSocket?.close(); await runtime.dispose(); }
});

test('account deletion media cleanup retains failed TURN revocation across restart', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-delete-media-'));
    const config = { ...options, TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
    let runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey] });
    try {
        const user = await enrolled(runtime);
        const ice = await call(runtime, `/api/rooms/${room}/ice/orphan`, { leaseID: 'delete-ice' }, user.accessToken);
        assert.equal(ice.status, 200);
        provider.revokeFails = true;
        const response = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(response.status, 200); assert.equal((await response.json()).mediaCleanupPending, true);
        assert.equal((await signIn(runtime, await challenge(runtime))).status, 409);
        await runtime.dispose(); provider.revokeFails = false;
        runtime = await makeRuntime(config, { storageDirectory, appleKeys: [publicKey], clockOffsetMs: 61000 });
        const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(retried.status, 200); assert.equal((await retried.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(r => r.url.includes('/credentials/') && r.url.endsWith('/revoke')));
    } finally { provider.revokeFails = false; await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});


for (const missingProvider of ['SFU', 'TURN']) {
    test(`media cleanup waits locally without ${missingProvider} credentials`, async () => {
        const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-delete-unconfigured-media-'));
        const config = { ...options, TURN_ENABLED: 'true', CLOUDFLARE_TURN_KEY_ID: 'test-turn', CLOUDFLARE_TURN_API_TOKEN: 'test-turn-secret' };
        const start = (overrides = {}, clockOffsetMs = 0) => makeRuntime({ ...config, ...overrides }, { storageDirectory, appleKeys: [publicKey], clockOffsetMs });
        let runtime = await start();
        try {
            const user = await enrolled(runtime);
            const base = `/api/rooms/${room}`;
            const ice = await call(runtime, `${base}/ice/owner`, { leaseID: 'delete-ice' }, user.accessToken);
            assert.equal(ice.status, 200);
            if (missingProvider === 'SFU') {
                const joined = await call(runtime, `${base}/join`, { participantId: 'owner', offer, iceLeaseID: 'delete-ice' }, user.accessToken);
                assert.equal(joined.status, 200);
            }
            await runtime.dispose();
            const paused = { SERVICE_ENABLED: 'false', TURN_ENABLED: 'false' };
            const binding = missingProvider === 'SFU' ? 'CLOUDFLARE_SFU_APP_SECRET' : 'CLOUDFLARE_TURN_API_TOKEN';
            runtime = await start({ ...paused, [binding]: '' });
            const before = provider.requests.length;
            const pending = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(pending.status, 200);
            assert.equal((await pending.json()).mediaCleanupPending, true);
            assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
            assert.equal(provider.requests.length, before, 'Unconfigured provider must receive no cleanup request');

            await runtime.dispose();
            runtime = await start(paused, 61000);
            const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
            assert.equal(retried.status, 200);
            assert.equal((await retried.json()).mediaCleanupPending, undefined);
            assert.ok(provider.requests.slice(before).some(request => request.url.endsWith('/revoke')));
        } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
    });
}

test('media remains pending until the SFU app that created it is configured again', async () => {
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-sfu-app-switch-'));
    const start = (appID, clockOffsetMs = 0) => makeRuntime({ ...options, CLOUDFLARE_SFU_APP_ID: appID },
        { storageDirectory, appleKeys: [publicKey], clockOffsetMs });
    let runtime = await start('first-app');
    try {
        const user = await enrolled(runtime);
        const other = await enrolled(runtime, 'different-account');
        const base = `/api/rooms/${room}`;
        const joined = await call(runtime, `${base}/join`, { participantId: 'original-peer', offer }, user.accessToken);
        assert.equal(joined.status, 200);
        const lease = await joined.json();
        assert.ok(!JSON.stringify(lease).includes('first-app'));
        const { sessionId } = lease;
        await runtime.dispose();

        runtime = await start('second-app');
        const before = provider.requests.length;
        provider.upstreamGone = true;
        const renewed = await call(runtime, `${base}/sessions/${sessionId}/renew`, {}, user.accessToken);
        const pending = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(pending.status, 200);
        assert.equal((await pending.json()).mediaCleanupPending, true, 'A response from the wrong app cannot complete cleanup');
        assert.equal(renewed.status, 503);
        assert.equal((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status, 401);
        const newPeer = await call(runtime, `${base}/join`, { participantId: 'next-peer', offer }, other.accessToken);
        assert.equal(newPeer.status, 503);
        assert.ok(!(await newPeer.text()).includes('second-app'));
        assert.equal(provider.requests.length, before, 'Prior session must stay out of the new SFU app');

        await runtime.dispose();
        provider.upstreamGone = false;
        runtime = await start('first-app', 61000);
        const retried = await call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        assert.equal(retried.status, 200);
        assert.equal((await retried.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.slice(before).some(request => request.url.endsWith(`/apps/first-app/sessions/${sessionId}/datachannels/close`)));
        const rejoined = await call(runtime, `${base}/join`, { participantId: 'next-peer', offer }, other.accessToken);
        assert.equal(rejoined.status, 200);
    } finally { provider.upstreamGone = false; await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});

test('account deletion collects a join already waiting for the SFU response', { timeout: 15000 }, async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey] });
    let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    const gate = new Promise(resolve => { release = resolve; });
    provider.onEstablish = async () => { entered(); await gate; };
    try {
        const user = await enrolled(runtime);
        const joining = call(runtime, `/api/rooms/${room}/join`, { participantId: 'joining-peer', offer }, user.accessToken);
        await started;
        const deleting = call(runtime, '/api/auth/account', undefined, user.accessToken, 'DELETE');
        const deadline = Date.now() + 3000;
        let retired = false;
        while (Date.now() < deadline) {
            if ((await call(runtime, '/api/auth/session', undefined, user.accessToken, 'GET')).status === 401) { retired = true; break; }
            await new Promise(resolve => setTimeout(resolve, 10));
        }
        release();
        assert.ok(retired, 'Credentials must retire while provider join is pending');
        const joined = await joining;
        assert.equal(joined.status, 200);
        const session = await joined.json();
        const deleted = await deleting;
        assert.equal(deleted.status, 200);
        assert.equal((await deleted.json()).mediaCleanupPending, undefined);
        assert.ok(provider.requests.some(request => request.url.endsWith(`/sessions/${session.sessionId}/datachannels/close`)));
        assert.equal((await call(runtime, `/api/rooms/${room}/sessions/${session.sessionId}/renew`, {}, user.accessToken)).status, 401);
        const fresh = await enrolled(runtime);
        assert.equal((await call(runtime, `/api/rooms/${room}/join`, { participantId: 'fresh-peer', offer }, fresh.accessToken)).status, 200);
    } finally { release(); delete provider.onEstablish; await runtime.dispose(); }
});


test('API quota is shared by verified devices while other accounts, revocation and deletion remain independent', async () => {
    const runtime = await makeRuntime(options, { appleKeys: [publicKey], apiLimit: 2 });
    try {
        const one = await (await signIn(runtime, await challenge(runtime))).json();
        const two = await (await signIn(runtime, await challenge(runtime))).json();
        const other = await (await signIn(runtime, await challenge(runtime), { sub: 'api-other-user' })).json();
        assert.equal((await call(runtime, '/api/status', undefined, one.accessToken, 'GET')).status, 200);
        assert.equal((await call(runtime, '/api/status', undefined, two.accessToken, 'GET')).status, 200);
        const denied = await call(runtime, '/api/status', undefined, two.accessToken, 'GET');
        assert.equal(denied.status, 429);
        assert.equal((await denied.json()).code, 'api_rate_limited');
        assert.equal((await call(runtime, '/api/status', undefined, other.accessToken, 'GET')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, two.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/status', undefined, two.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/notifications/device', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/notifications/grants', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/account', undefined, one.accessToken, 'DELETE')).status, 200);
        assert.equal((await call(runtime, '/api/auth/session', undefined, one.accessToken, 'GET')).status, 401);
        assert.equal((await call(runtime, '/api/auth/session', undefined, other.accessToken, 'GET')).status, 200);
    } finally { await runtime.dispose(); }
});
