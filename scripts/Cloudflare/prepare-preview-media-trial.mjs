import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const hash = value => createHash('sha256').update(value).digest('hex');

console.error('固定Previewの音声試験では、今回の試験設定を含む共有mainから preview ブランチを作り直し、再デプロイを確認してから接続してください。');

const directory = mkdtempSync(join(tmpdir(), 'ridecom-preview-media-'));
const room = randomUUID().toUpperCase();
const groupSecret = randomBytes(32).toString('base64url');
const issue = () => `preview-media.${randomBytes(32).toString('base64url')}`;
const leftToken = issue();
const rightToken = issue();
const issuedAt = Date.now();
const grant = {
    room: hash(`${room}\0${groupSecret}`),
    issuedAt,
    expiresAt: issuedAt + 20 * 60 * 1000,
    participants: {
        [hash(leftToken)]: `e2e-a-${room.slice(0, 8)}`,
        [hash(rightToken)]: `e2e-b-${room.slice(0, 8)}`
    }
};
writeFileSync(join(directory, 'credentials.json'), JSON.stringify({ leftToken, rightToken, room, groupSecret }), { mode: 0o600 });
writeFileSync(join(directory, 'grant.toml'), `TEST_PREVIEW_MEDIA_TRIAL = ${JSON.stringify(JSON.stringify(grant))}\n`, { mode: 0o600 });
console.log(directory);
