import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { BitString, Integer, Utf8String } from 'asn1js';
import { encode } from 'cborg';
import { Miniflare } from 'miniflare';
import { AttributeTypeAndValue, BasicConstraints, Certificate, CryptoEngine, Extension } from 'pkijs';

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

async function issueCertificate(name, { authority, key, extensions = [], expires = checkTime + 600_000 } = {}) {
    const keys = key ?? await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const certificate = new Certificate();
    certificate.version = 2;
    certificate.serialNumber = new Integer({ value: ++serialNumber });
    certificate.subject.typesAndValues.push(new AttributeTypeAndValue({
        type: '2.5.4.3', value: new Utf8String({ value: name })
    }));
    certificate.issuer = authority?.certificate.subject ?? certificate.subject;
    certificate.notBefore.value = new Date(checkTime - 600_000);
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
        counter = 0, accessControl = acl, expires, duplicate = false } = {}) {
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
        authority, key: keys, expires, extensions: [
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
