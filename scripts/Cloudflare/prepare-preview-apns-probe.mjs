import { createHash, randomBytes } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [tokenFile, ...extra] = process.argv.slice(2);
if (extra.length) throw new Error('Supply at most one path to a dedicated Sandbox test device token file');
const token = tokenFile ? readFileSync(tokenFile, 'utf8').trim().toLowerCase() : '00'.repeat(32);
if (!/^(?:[a-f0-9]{2}){1,2048}$/.test(token)) throw new Error('Expected a hexadecimal Sandbox test destination');

const hash = value => createHash('sha256').update(value).digest('hex');
const credential = `preview-apns.${randomBytes(32).toString('base64url')}`;
const issuedAt = Date.now();
const grant = { issuedAt, expiresAt: issuedAt + 20 * 60 * 1000,
    credentialDigest: hash(credential), destinationDigest: hash(token) };
const directory = mkdtempSync(join(tmpdir(), 'ridecom-preview-apns-'));
writeFileSync(join(directory, 'headers'), `Authorization: Bearer ${credential}\nContent-Type: application/json\n`, { mode: 0o600 });
writeFileSync(join(directory, 'request.json'), JSON.stringify({ token }), { mode: 0o600 });
writeFileSync(join(directory, 'grant.toml'), `TEST_PREVIEW_SANDBOX_APNS_PROBE = ${JSON.stringify(JSON.stringify(grant))}\n`, { mode: 0o600 });
console.log(directory);
