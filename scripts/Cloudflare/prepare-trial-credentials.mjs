#!/usr/bin/env node
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename, extname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { hashTrialToken, issueDevice, trialOrigin, validateTrialOwner } from './issue-device.mjs';

function readTrialDevice(path, origin) {
    const file = lstatSync(path);
    if (!file.isFile() || (file.mode & 0o777) !== 0o600 || extname(path) !== '.json') {
        throw new Error('Use a private trial device JSON file');
    }
    const owner = basename(path, '.json');
    validateTrialOwner(owner);
    let device;
    try {
        device = JSON.parse(readFileSync(path, 'utf8'));
    } catch {
        throw new Error('Invalid trial device file');
    }
    const token = device?.accessToken;
    if (device?.workerURL !== origin || typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) {
        throw new Error('Each device must have an issued trial credential for this service origin');
    }
    return { owner, hash: hashTrialToken(token) };
}

export function prepareTrialCredentials(endpoint, root, devices = []) {
    const origin = trialOrigin(endpoint);
    if (devices.length !== 0 && devices.length !== 2) throw new Error('Select both trial device files or generate a new pair');
    const entries = devices.map(path => readTrialDevice(path, origin));
    if (entries.length === 2 && (entries[0].owner === entries[1].owner || entries[0].hash === entries[1].hash)) {
        throw new Error('Use two distinct trial devices');
    }

    mkdirSync(root, { recursive: true, mode: 0o700 });
    const parent = lstatSync(root);
    if (!parent.isDirectory() || (parent.mode & 0o777) !== 0o700) throw new Error('Use a private trial credential directory');
    const directory = mkdtempSync(join(root, 'pair-'));
    const registryPath = join(directory, 'client-tokens.json');
    try {
        if (entries.length) {
            const registry = Object.fromEntries(entries.map(({ hash, owner }) => [hash, owner]));
            writeFileSync(registryPath, `${JSON.stringify(registry, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
        } else {
            const name = basename(directory);
            issueDevice(origin, `${name}-a`, directory);
            issueDevice(origin, `${name}-b`, directory);
        }
    } catch (error) {
        rmSync(directory, { recursive: true, force: true });
        throw error;
    }
    return { directory, registryPath };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
    try {
        const [endpoint, ...devices] = process.argv.slice(2);
        if (!endpoint) throw new Error('Usage: node scripts/Cloudflare/prepare-trial-credentials.mjs https://preview.example [device-a.json device-b.json]');
        const { directory } = prepareTrialCredentials(endpoint, resolve('server/.trial-credentials'), devices);
        console.log(directory);
    } catch (error) {
        console.error(error.message);
        process.exitCode = 1;
    }
}
