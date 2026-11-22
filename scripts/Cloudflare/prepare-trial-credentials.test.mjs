import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { hashTrialToken, issueDevice } from './issue-device.mjs';
import { prepareTrialCredentials } from './prepare-trial-credentials.mjs';

const preview = 'https://preview.test';
const readJSON = path => JSON.parse(readFileSync(path, 'utf8'));

function withDirectory(t) {
    const directory = mkdtempSync(join(tmpdir(), 'ridecom-preview-trial-'));
    t.after(() => rmSync(directory, { recursive: true, force: true }));
    return directory;
}

test('fresh runs produce two private credentials with distinct trial owners', t => {
    const root = withDirectory(t);
    const first = prepareTrialCredentials(preview, root);
    const second = prepareTrialCredentials(preview, root);
    assert.notEqual(first.directory, second.directory);
    const registries = [first, second].map(({ directory, registryPath }) => {
        assert.equal(statSync(directory).mode & 0o777, 0o700);
        assert.equal(statSync(registryPath).mode & 0o777, 0o600);
        const registry = readJSON(registryPath);
        assert.equal(Object.keys(registry).length, 2);
        for (const role of ['a', 'b']) {
            const owner = `${basename(directory)}-${role}`;
            const path = join(directory, `${owner}.json`);
            assert.equal(statSync(path).mode & 0o777, 0o600);
            const device = readJSON(path);
            assert.equal(device.workerURL, preview);
            assert.equal(registry[hashTrialToken(device.accessToken)], owner);
        }
        return registry;
    });
    assert.equal(new Set(registries.flatMap(registry => Object.values(registry))).size, 4);
    assert.equal(new Set(registries.flatMap(registry => Object.keys(registry))).size, 4);
});

test('reuse reconstructs the same registry without replacing or copying credentials', t => {
    const root = withDirectory(t);
    const source = join(root, 'source');
    const a = issueDevice(preview, 'mac', source);
    const b = issueDevice(preview, 'phone', source);
    const originalRegistry = readJSON(a.registryPath);
    const originalDevices = [a, b].map(({ devicePath }) => readFileSync(devicePath));
    rmSync(a.registryPath);
    const rebuilt = prepareTrialCredentials(preview, root, [a.devicePath, b.devicePath]);
    assert.deepEqual(readJSON(rebuilt.registryPath), originalRegistry);
    assert.deepEqual(readdirSync(rebuilt.directory), ['client-tokens.json']);
    assert.deepEqual([a, b].map(({ devicePath }) => readFileSync(devicePath)), originalDevices);
    assert.equal(existsSync(a.registryPath), false);
});

test('incomplete, duplicate, cross-environment and exposed inputs leave no registry', t => {
    const root = withDirectory(t);
    const path = join(root, 'source');
    const a = issueDevice(preview, 'mac', path);
    const b = issueDevice('https://other.test', 'phone', path);
    assert.throws(() => prepareTrialCredentials(preview, root, [a.devicePath]), /Select both/);
    assert.throws(() => prepareTrialCredentials(preview, root, [a.devicePath, a.devicePath]), /distinct/);
    assert.throws(() => prepareTrialCredentials(preview, root, [a.devicePath, b.devicePath]), /service origin/);
    chmodSync(a.devicePath, 0o644);
    assert.throws(() => prepareTrialCredentials(preview, root, [a.devicePath, b.devicePath]), /private trial device/);
    assert.deepEqual(readdirSync(root), ['source']);
});

test('the CLI reports only the new private directory', t => {
    const cwd = withDirectory(t);
    const entry = fileURLToPath(new URL('./prepare-trial-credentials.mjs', import.meta.url));
    const output = execFileSync(process.execPath, [entry, preview], { cwd, encoding: 'utf8' });
    const root = join(realpathSync(cwd), 'server', '.trial-credentials');
    const [name] = readdirSync(root);
    assert.equal(output, `${join(root, name)}\n`);
    assert.equal(Object.keys(readJSON(join(root, name, 'client-tokens.json'))).length, 2);
});
