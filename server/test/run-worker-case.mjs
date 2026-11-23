import { realpath } from 'node:fs/promises';
import { join } from 'node:path';
import { run } from 'node:test';
import { fileURLToPath } from 'node:url';
import { inspect } from 'node:util';
import { listWorkerCases } from './worker-cases.mjs';

const preload = new URL('./support/select-worker-case.mjs', import.meta.url).href;
const serverRoot = fileURLToPath(new URL('../', import.meta.url));

function issueDetails(error) {
    const issue = error?.cause ?? error;
    const render = value => inspect(value, { depth: 4, maxArrayLength: 30, maxStringLength: 1500 }).slice(0, 8000);
    return {
        message: String(issue?.message ?? issue).slice(0, 8000),
        stack: issue?.stack?.slice(0, 8000),
        expected: issue?.expected === undefined ? undefined : render(issue.expected),
        actual: issue?.actual === undefined ? undefined : render(issue.actual),
    };
}

export async function runWorkerCase(selection, directory = new URL('./', import.meta.url)) {
    const { file, names, occurrence } = selection ?? {};
    if (typeof file !== 'string' || !Array.isArray(names) || !names.length
        || !names.every(name => typeof name === 'string') || !Number.isSafeInteger(occurrence) || occurrence < 1) {
        throw new TypeError('Select a case from the Worker test list');
    }
    const expectedNames = JSON.stringify(names);
    const selected = (await listWorkerCases(directory, file)).find(candidate =>
        candidate.occurrence === occurrence && JSON.stringify(candidate.names) === expectedNames);
    if (!selected) return { status: 'missing', message: 'The selected case is no longer registered' };

    const source = join(await realpath(directory), selected.file);
    const events = run({
        cwd: serverRoot, files: [source], argv: [JSON.stringify(selected)],
        execArgv: ['--import', preload], timeout: 120_000,
    });
    const cases = [];
    const failures = [];
    let unexpected = 0;
    let output = '';
    for await (const { type, data } of events) {
        if (type === 'test:stdout' || type === 'test:stderr' || type === 'test:diagnostic') {
            output = `${output}${data.message}\n`.slice(0, 16_000);
        }
        if (type !== 'test:pass' && type !== 'test:fail') continue;
        if (type === 'test:fail') failures.push(issueDetails(data.details?.error));
        if (data.details?.type === 'suite' || data.name === source || data.nesting > names.length - 1) continue;
        if (data.nesting !== names.length - 1 || data.name !== names.at(-1)) {
            unexpected += 1;
            continue;
        }
        cases.push({
            status: data.skip || data.todo ? 'skipped' : type === 'test:pass' ? 'passed' : 'failed',
            skipReason: data.skip || data.todo || undefined,
            durationMs: data.details?.duration_ms,
        });
    }
    if (cases.length !== 1 || unexpected !== 0) {
        return { case: selected, status: 'failed', message: 'Expected exactly one result for the selected case',
            count: cases.length, unexpected, failures, output };
    }
    const result = cases[0];
    return { case: selected, ...result, status: failures.length ? 'failed' : result.status, failures, output };
}

if (import.meta.main) {
    Promise.resolve().then(() => runWorkerCase(JSON.parse(process.argv[2]))).then(result => {
        process.stdout.write(`${JSON.stringify(result)}\n`);
        if (result.status !== 'passed') process.exitCode = 1;
    }).catch(error => {
        process.stdout.write(`${JSON.stringify({ status: 'failed', failures: [issueDetails(error)] })}\n`);
        process.exitCode = 1;
    });
}
