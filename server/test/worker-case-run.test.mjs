import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execute = promisify(execFile);

test('Worker selection runs one registered case and keeps the native failure or skip details', async () => {
    const folder = await mkdtemp(join(tmpdir(), 'ridecom-worker-selection-'));
    try {
        const directory = pathToFileURL(`${folder}/`);
        const file = 'selection.test.mjs';
        const launcher = new URL('driver.mjs', directory);
        const driver = new URL('./run-worker-case.mjs', import.meta.url);
        await writeFile(launcher, `
            import { runWorkerCase } from ${JSON.stringify(driver.href)};
            const result = await runWorkerCase(JSON.parse(process.argv[2]), new URL('./', import.meta.url));
            process.stdout.write(JSON.stringify(result));
        `);
        await writeFile(new URL(file, directory), `
            import assert from 'node:assert/strict';
            import { beforeEach, describe, test } from 'node:test';
            describe('first', () => {
                beforeEach(() => { throw new Error('The other suite should not run'); });
                test('same name', () => {});
            });
            describe('second', () => {
                let prepared = false;
                beforeEach(() => { prepared = true; });
                test('same name', () => { throw new Error('The first occurrence should not run'); });
                test('same name', () => { assert.ok(prepared); });
            });
            test('intentional failure', () => {
                console.log('diagnostic from selected test');
                assert.equal(2, 1, 'Numbers do not match');
            });
            test('intentional skip', { skip: 'fixture unavailable' }, () => {});
        `);
        const run = async (names, occurrence = 1) => {
            const { stdout } = await execute(process.execPath, [
                fileURLToPath(launcher), JSON.stringify({ file, names, occurrence }),
            ], { env: { PATH: process.env.PATH, TMPDIR: folder } });
            return JSON.parse(stdout);
        };
        const selected = { file, names: ['second', 'same name'], occurrence: 2 };
        const success = await run(selected.names, selected.occurrence);
        assert.equal(success.status, 'passed', JSON.stringify(success.failures));
        assert.deepEqual(success.case, selected);
        assert.ok(success.durationMs >= 0);

        const failed = await run(['intentional failure']);
        assert.equal(failed.status, 'failed');
        assert.equal(failed.failures[0].expected, '1');
        assert.equal(failed.failures[0].actual, '2');
        assert.match(failed.failures[0].stack, /selection\.test\.mjs:\d+/);
        assert.match(failed.output, /diagnostic from selected test/);
        const skipped = await run(['intentional skip']);
        assert.equal(skipped.status, 'skipped');
        assert.equal(skipped.skipReason, 'fixture unavailable');
        assert.equal((await run(['removed case'])).status, 'missing');
    } finally {
        await rm(folder, { recursive: true, force: true });
    }
});
