import assert from 'node:assert/strict';
import { mkdtemp, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { listWorkerCases } from './worker-cases.mjs';

test('Worker test discovery lists parameterized and same-name registrations without running test bodies', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'ridecom-worker-cases-'));
    try {
        const directory = pathToFileURL(`${folder}/`);
        const file = 'registration.test.mjs';
        await writeFile(new URL(file, directory), `
            import test, { before, describe, it } from 'node:test';
            function unexpected() { throw new Error('A body or hook ran during discovery'); }
            before(unexpected);
            for (const group of ['first', 'second']) {
                describe(group, () => it('same name', unexpected));
            }
            test('repeated', unexpected);
            test('repeated', unexpected);
        `);
        await writeFile(new URL('support.mjs', directory), 'throw new Error("Only test files are listed");');
        assert.deepEqual(await listWorkerCases(directory), [
            { file, names: ['first', 'same name'], occurrence: 1 },
            { file, names: ['second', 'same name'], occurrence: 1 },
            { file, names: ['repeated'], occurrence: 1 },
            { file, names: ['repeated'], occurrence: 2 },
        ]);
        const renamed = 'renamed.test.mjs';
        await rename(new URL(file, directory), new URL(renamed, directory));
        await writeFile(new URL(renamed, directory),
            "import { test } from 'node:test'; test('changed', () => {});");
        assert.deepEqual(await listWorkerCases(directory), [
            { file: renamed, names: ['changed'], occurrence: 1 },
        ]);
    } finally {
        await rm(folder, { recursive: true, force: true });
    }
});
