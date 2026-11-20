import assert from 'node:assert/strict';
import { createHash, randomUUID, webcrypto } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { BitString, Integer, Utf8String } from 'asn1js';
import { encode } from 'cborg';
import { Miniflare } from 'miniflare';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import { AttributeTypeAndValue, BasicConstraints, Certificate, CryptoEngine, Extension } from 'pkijs';
import { makeRuntime } from './support/runtime.mjs';

const appID = 'RIDE123456.com.example.ridecom';
const challenge = 'a1'.repeat(32);
const checkTime = Date.parse('2026-11-20T10:00:00Z');
const expected = { appID, environment: 'production', validationCategory: 3, bundleVersion: null };
const acl = Buffer.from('MEAMAjExMDowCQwCb2uhAwEB/zAJDAJvYaEDAQH/MAsMBG9kZWyhAwEB/zAVDARvc2duoAYMBHJzZWMwBaYDAgEB', 'base64');
const digest = bytes => createHash('sha256').update(bytes).digest();
const subtle = webcrypto.subtle;
const engine = new CryptoEngine({ crypto: webcrypto });
let serialNumber = 0;

const extension = (extnID, bytes, critical = false) =>
    new Extension({ extnID, critical, extnValue: Uint8Array.from(Buffer.from(bytes)).buffer });
const wrapped = (bytes, tag = 0xa1) => Buffer.concat([Buffer.from([0x30, bytes.length + 4, tag, bytes.length + 2, 4, bytes.length]), bytes]);

async function issueCertificate(name, { authority, key, extensions = [], validAt = checkTime, expires = validAt + 600_000 } = {}) {
    const keys = key ?? await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const certificate = new Certificate();
    certificate.version = 2;
    certificate.serialNumber = new Integer({ value: ++serialNumber });
    certificate.subject.typesAndValues.push(new AttributeTypeAndValue({
        type: '2.5.4.3', value: new Utf8String({ value: name })
    }));
    certificate.issuer = authority?.certificate.subject ?? certificate.subject;
    certificate.notBefore.value = new Date(validAt - 600_000);
    certificate.notAfter.value = new Date(expires);
    certificate.extensions = extensions;
    await certificate.subjectPublicKeyInfo.importKey(keys.publicKey, engine);
    await certificate.sign(authority?.keys.privateKey ?? keys.privateKey, 'SHA-256', engine);
    return { keys, certificate, der: new Uint8Array(certificate.toSchema().toBER(false)) };
}

function caExtensions(pathLenConstraint) {
    return [
        extension('2.5.29.19', new BasicConstraints({ cA: true, pathLenConstraint }).toSchema().toBER(false), true),
        extension('2.5.29.15', new BitString({ valueHex: new Uint8Array([4]).buffer, unusedBits: 2 }).toBER(false), true)
    ];
}

async function proof(authority, { key, category = 3, version, environment = 'production', nonce = challenge,
        counter = 0, accessControl = acl, validAt, expires, duplicate = false } = {}) {
    const keys = key ?? await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const point = Buffer.from(await subtle.exportKey('raw', keys.publicKey));
    const keyIdentifier = digest(point);
    const header = Buffer.alloc(55);
    header.set(digest(appID));
    header[32] = 0xc0;
    header.writeUInt32BE(counter, 33);
    header.set(Buffer.from(environment === 'production' ? 'appattest\0\0\0\0\0\0\0' : 'appattestdevelop'), 37);
    header.writeUInt16BE(32, 53);
    const keyMap = new Map([[1, 2], [3, -7], [-1, 1], [-2, point.subarray(1, 33)], [-3, point.subarray(33)]]);
    const fields = { apple_validation_category_01: Uint8Array.of(category, 0, 0, 0) };
    if (version !== undefined) fields.apple_bundle_version_01 = version;
    const authData = Buffer.concat([header, keyIdentifier, encode(keyMap), encode(fields)]);
    const appleNonce = wrapped(digest(Buffer.concat([authData, digest(nonce)])));
    const chain = await issueCertificate('Fake attested device', {
        authority, key: keys, validAt, expires, extensions: [
            extension('1.2.840.113635.100.8.2', appleNonce),
            ...(duplicate ? [extension('1.2.840.113635.100.8.2', appleNonce)] : []),
            ...(accessControl ? [extension('1.2.840.113635.100.8.6', wrapped(accessControl, 0xa3))] : [])
        ]
    });
    return {
        keyID: keyIdentifier.toString('base64'),
        publicKey: point.toString('base64url'),
        attestation: Buffer.from(encode({
            fmt: 'apple-appattest', authData,
            attStmt: { x5c: [chain.der, authority.der], receipt: Uint8Array.of(1) }
        })).toString('base64')
    };
}

test('local Worker validates a key proof only for the pinned certificate chain and enrollment policy', async () => {
    const ca = await issueCertificate('Test trust anchor', { extensions: caExtensions(1) });
    const intermediate = await issueCertificate('Test App Attestation CA', { authority: ca, extensions: caExtensions(0) });
    const good = await proof(intermediate);
    const runtime = new Miniflare({
        modules: [
            { type: 'ESModule', path: 'fixture.mjs', contents: `
                import { createAppAttestEnrollmentVerifier } from './index.js';
                const bytes = x => Uint8Array.from(atob(x), c => c.charCodeAt(0));
                export default { async fetch(request) {
                    const input = await request.json();
                    const verify = createAppAttestEnrollmentVerifier(input.testRoot ? bytes(input.testRoot) : undefined);
                    const result = await verify(bytes(input.attestation), input.keyID, input.challenge, input.policy, new Date(input.checkTime));
                    return Response.json(result);
                } };
            ` },
            { type: 'ESModule', path: 'index.js', contents: await readFile('dist/index.js', 'utf8') }
        ],
        compatibilityDate: '2024-11-01'
    });
    const verify = async (changes = {}) => (await runtime.dispatchFetch('https://enrollment.test/', {
        method: 'POST', body: JSON.stringify({
            testRoot: Buffer.from(ca.der).toString('base64'),
            attestation: good.attestation, keyID: good.keyID, challenge,
            policy: expected, checkTime, ...changes
        })
    })).json();
    try {
        assert.deepEqual(await verify(), { publicKey: good.publicKey, appID, validationCategory: 3, bundleVersion: null, counter: 0 });
        for (const changes of [
            { testRoot: null }, { keyID: Buffer.alloc(32).toString('base64') },
            { challenge: 'a2'.repeat(32) }, { policy: { ...expected, appID: 'RIDE123456.com.example.other' } },
            { policy: { ...expected, environment: 'development' } }, { policy: { ...expected, validationCategory: 4 } },
            { policy: { ...expected, bundleVersion: '1586' } }, { checkTime: checkTime + 600_001 },
            { attestation: Buffer.alloc(16_385).toString('base64') }
        ]) assert.equal(await verify(changes), null);
        for (const fields of [
            { nonce: 'b2'.repeat(32) }, { environment: 'development' }, { counter: 1 },
            { accessControl: null }, { accessControl: Buffer.alloc(acl.length) }, { duplicate: true }
        ]) assert.equal(await verify(await proof(intermediate, fields)), null);
        const release = await proof(intermediate, { category: 4, version: '1586' });
        const releasePolicy = { ...expected, validationCategory: 4, bundleVersion: '1586' };
        assert.deepEqual(await verify({ ...release, policy: releasePolicy }), {
            publicKey: release.publicKey, appID, validationCategory: 4, bundleVersion: '1586', counter: 0
        });
    } finally { await runtime.dispose(); }
});

test('authenticated enrollment consumes only the owning device challenge and serializes reuse of the same key', async () => {
    const validAt = Date.now();
    const ca = await issueCertificate('Test trust anchor', { validAt, extensions: caExtensions(1) });
    const issuer = await issueCertificate('Test App Attestation CA', { authority: ca, validAt, extensions: caExtensions(0) });
    const apple = await generateKeyPair('RS256');
    const appleKeys = [{ ...await exportJWK(apple.publicKey), kid: 'subject-fixture', alg: 'RS256' }];
    const audience = appID.slice(11);
    const config = { APPLE_AUTH_ENABLED: 'true', APPLE_CLIENT_ID: audience, DEVICE_ATTESTATION_ENABLED: 'true',
        DEVICE_ATTESTATION_MAC_POLICY: JSON.stringify(expected) };
    const storageDirectory = await mkdtemp(join(tmpdir(), 'ride-app-attest-enroll-'));
    let afterVerification;
    const open = () => makeRuntime(config, { appleKeys, storageDirectory,
        attestationRoot: Buffer.from(ca.der).toString('base64'), onAttestationVerified: () => afterVerification?.() });
    let runtime = await open();
    function request(path, body, token, method = 'POST') {
        return runtime.dispatchFetch('https://worker.test' + path, {
            method, headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': '192.0.2.1',
                ...(token ? { Authorization: 'Bearer ' + token } : {}) },
            ...(body === undefined ? {} : { body: JSON.stringify(body) })
        });
    }
    async function device(subject, deviceID = randomUUID()) {
        const issued = await (await request('/api/auth/apple/challenge', { deviceID })).json();
        const token = await new SignJWT({ nonce: issued.nonce }).setProtectedHeader({ alg: 'RS256', kid: 'subject-fixture' })
            .setSubject(subject).setIssuer('https://appleid.apple.com').setAudience(audience)
            .setIssuedAt().setExpirationTime('5m').sign(apple.privateKey);
        const response = await request('/api/auth/apple/session', { challengeID: issued.challengeID, identityToken: token });
        assert.equal(response.status, 200);
        return { deviceID, ...await response.json() };
    }
    async function attempt(owner, key) {
        const response = await request('/api/auth/device-attestation/challenge', {}, owner.accessToken);
        assert.equal(response.status, 200);
        const { nonce } = await response.json();
        const { keyID, attestation } = await proof(issuer, { key, nonce, validAt });
        return { nonce, keyID, attestation };
    }
    const path = '/api/auth/device-attestation';
    try {
        const a = await device('first-person'), b = await device('second-person');
        const extra = await device('first-person');
        const shared = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
        const one = await attempt(a, shared), two = await attempt(b, shared);
        assert.equal((await request(path, one, extra.accessToken)).status, 401);
        assert.equal((await request(path, { ...one, attestation: two.attestation }, a.accessToken)).status, 401);
        const results = await Promise.all([request(path, one, a.accessToken), request(path, two, b.accessToken)]);
        assert.deepEqual(results.map(response => response.status).sort(), [200, 409]);
        const [winner, accepted, subject, loser, rejected] = results[0].ok
            ? [a, one, 'first-person', b, two] : [b, two, 'second-person', a, one];
        const success = await request(path, accepted, winner.accessToken);
        assert.equal(success.status, 200);
        assert.deepEqual(await success.json(), { registered: true, expiresAt: winner.expiresAt });
        assert.equal((await request(path, { ...accepted, keyID: Buffer.alloc(32).toString('base64') }, winner.accessToken)).status, 401);

        await runtime.dispose();
        runtime = await open();
        assert.equal((await request(path, accepted, winner.accessToken)).status, 200);
        assert.equal((await request(path, rejected, loser.accessToken)).status, 409);
        const renewed = await device(subject, winner.deviceID);
        assert.equal((await request(path, accepted, winner.accessToken)).status, 401);
        assert.equal((await request(path, accepted, renewed.accessToken)).status, 200);
        assert.equal((await request('/api/auth/session', undefined, renewed.accessToken, 'DELETE')).status, 200);
        assert.equal((await request(path, accepted, renewed.accessToken)).status, 401);
        assert.equal((await request(path, rejected, loser.accessToken)).status, 200);

        const another = await device('third-person');
        const submitted = await attempt(another, shared);
        assert.equal((await request(path, submitted, another.accessToken)).status, 409);
        assert.equal((await request('/api/auth/account', undefined, loser.accessToken, 'DELETE')).status, 200);

        const reached = Promise.withResolvers();
        const resume = Promise.withResolvers();
        afterVerification = () => { reached.resolve(); return resume.promise; };
        const inFlight = request(path, submitted, another.accessToken);
        try {
            await Promise.race([reached.promise, inFlight.then(() => assert.fail('Verification did not suspend'))]);
            assert.equal((await request('/api/auth/session', undefined, another.accessToken, 'DELETE')).status, 200);
        } finally {
            afterVerification = undefined;
            resume.resolve();
        }
        assert.equal((await inFlight).status, 401);
        const newDevice = await device('fourth-person');
        assert.equal((await request(path, await attempt(newDevice, shared), newDevice.accessToken)).status, 200);
    } finally { await runtime.dispose(); await rm(storageDirectory, { recursive: true, force: true }); }
});
