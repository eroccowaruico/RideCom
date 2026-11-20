import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { Miniflare } from 'miniflare';

const appID = 'RIDECOM123.com.example.ridecom';
const nonce = 'a1'.repeat(32);
const operationHash = createHash('sha256').update('fixture group / member / removal').digest('hex');
const nextNonce = 'b2'.repeat(32);
const bundleVersion = '1584';
const stateKey = 'fixture-device';

function device() {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    const { x, y } = publicKey.export({ format: 'jwk' });
    return { privateKey, publicKey: Buffer.concat([Buffer.from([4]), Buffer.from(x, 'base64url'), Buffer.from(y, 'base64url')]).toString('base64url') };
}

function cborValue(type, value) {
    const bytes = Buffer.from(value);
    return Buffer.concat([Buffer.from(bytes.length < 24
        ? [(type << 5) | bytes.length] : [(type << 5) | 24, bytes.length]), bytes]);
}

function cborMap(entries) {
    return Buffer.concat([Buffer.from([0xa0 | entries.length]), ...entries.flatMap(([key, type, value]) =>
        [cborValue(3, key), cborValue(type, value)])]);
}

function assertion(privateKey, { app = appID, counter = 1, challenge = nonce, operation = operationHash,
        category = 2, version = bundleVersion, includeExtensions = true, duplicateExtension = false,
        trailingSignatureByte = false } = {}) {
    const header = Buffer.alloc(37);
    header.set(createHash('sha256').update(app).digest());
    header[32] = includeExtensions ? 0x80 : 0;
    header.writeUInt32BE(counter, 33);
    const extensions = [['apple_validation_category_01', 2, [category, 0, 0, 0]], ['apple_bundle_version_01', 3, version]];
    if (duplicateExtension) extensions[1] = extensions[0];
    const authenticatorData = includeExtensions ? Buffer.concat([header, cborMap(extensions)]) : header;
    const clientData = JSON.stringify(['rideintercom.group-removal.v1', challenge, operation]);
    const signature = sign('sha256', Buffer.concat([authenticatorData, createHash('sha256').update(clientData).digest()]), privateKey);
    return cborMap([['signature', 2, trailingSignatureByte ? Buffer.concat([signature, Buffer.from([0])]) : signature],
        ['authenticatorData', 2, authenticatorData]]);
}

async function fixture() {
    const runtime = new Miniflare({
        modules: [
            { type: 'ESModule', path: 'fixture.mjs', contents: `
                import { DurableObject } from 'cloudflare:workers';
                import { consumeGroupRemovalAssertion } from './index.js';
                export class Fixture extends DurableObject {
                    async fetch(request) {
                        const key = '${stateKey}';
                        if (request.method === 'GET') return Response.json(this.ctx.storage.kv.get(key) ?? null);
                        const body = await request.json();
                        if (request.method === 'PUT') {
                            this.ctx.storage.kv.put(key, body);
                            return new Response(null, { status: 204 });
                        }
                        const bytes = Uint8Array.from(atob(body.assertion), c => c.charCodeAt(0));
                        return Response.json(await consumeGroupRemovalAssertion(this.ctx.storage, key, body.operationHash, bytes));
                    }
                }
                export default { fetch: (request, env) => env.FIXTURE.getByName('test').fetch(request) };
            ` },
            { type: 'ESModule', path: 'index.js', contents: await readFile('dist/index.js', 'utf8') }
        ],
        compatibilityDate: '2024-11-01',
        durableObjects: { FIXTURE: { className: 'Fixture', useSQLite: true } }
    });
    return {
        close: () => runtime.dispose(),
        async set(value) {
            const result = await runtime.dispatchFetch('https://fixture.test/', { method: 'PUT', body: JSON.stringify(value) });
            assert.equal(result.status, 204);
        },
        async state() { return (await runtime.dispatchFetch('https://fixture.test/')).json(); },
        async consume(bytes, hash = operationHash) {
            const result = await runtime.dispatchFetch('https://fixture.test/', {
                method: 'POST', body: JSON.stringify({ assertion: bytes.toString('base64'), operationHash: hash })
            });
            assert.equal(result.status, 200);
            return result.json();
        }
    };
}

function registration(key, counter = 0, challenge = nonce) {
    return { publicKey: key.publicKey, appID, validationCategory: 2, bundleVersion, counter,
        challenge: { nonce: challenge, operationHash, expiresAt: Date.now() + 60_000 } };
}

test('the Worker consumes a verified removal challenge exactly once and advances its counter', async () => {
    const runtime = await fixture(), key = device();
    try {
        await runtime.set(registration(key));
        const proof = assertion(key.privateKey);
        const attempts = await Promise.all([runtime.consume(proof), runtime.consume(proof)]);
        assert.equal(attempts.filter(result => result === 1).length, 1);
        assert.equal(attempts.filter(result => result === null).length, 1);
        assert.equal((await runtime.state()).counter, 1);
        assert.equal((await runtime.state()).challenge, undefined);

        await runtime.set(registration(key, 1, nextNonce));
        assert.equal(await runtime.consume(assertion(key.privateKey, { challenge: nextNonce })), null);
        assert.equal(await runtime.consume(assertion(key.privateKey, { counter: 2 })), null);
        assert.equal(await runtime.consume(assertion(key.privateKey, { challenge: nextNonce, counter: 3 })), 3);
    } finally { await runtime.close(); }
});

test('wrong operation, device or app identity and invalid envelopes preserve the pending challenge', async () => {
    const runtime = await fixture(), key = device();
    try {
        const record = registration(key);
        await runtime.set(record);
        const alternateOperation = 'c3'.repeat(32);
        for (const proof of [
            assertion(key.privateKey, { operation: alternateOperation }),
            assertion(device().privateKey),
            assertion(key.privateKey, { app: 'RIDECOM123.com.example.other' }),
            assertion(key.privateKey, { category: 3 }),
            assertion(key.privateKey, { version: '9999' }),
            assertion(key.privateKey, { includeExtensions: false }),
            assertion(key.privateKey, { duplicateExtension: true }),
            assertion(key.privateKey, { trailingSignatureByte: true }),
            Buffer.concat([assertion(key.privateKey), Buffer.from([0])]),
            Buffer.alloc(4097)
        ]) assert.equal(await runtime.consume(proof), null);
        assert.equal(await runtime.consume(assertion(key.privateKey), alternateOperation), null);
        assert.deepEqual(await runtime.state(), record);
        record.challenge.expiresAt = Date.now() - 1;
        await runtime.set(record);
        assert.equal(await runtime.consume(assertion(key.privateKey)), null);
        assert.deepEqual(await runtime.state(), record);
    } finally { await runtime.close(); }
});
