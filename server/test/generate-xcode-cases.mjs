import { createHash } from 'node:crypto';
import { listWorkerCases } from './worker-cases.mjs';

const declarations = [];
const identifiers = new Set();
for (const selected of await listWorkerCases()) {
    const payload = JSON.stringify(selected);
    const hash = createHash('sha256').update(payload).digest('hex').slice(0, 12);
    const label = [selected.file.replace(/\.test\.mjs$/, ''), ...selected.names]
        .join('_').replace(/[^A-Za-z0-9]+/g, '_').slice(0, 100).replace(/_$/, '');
    const identifier = `test_${label}_${hash}`;
    if (identifiers.has(identifier)) throw new Error('Duplicate generated Worker test identifier');
    identifiers.add(identifier);
    declarations.push(
        `    func ${identifier}() throws {\n        try runWorkerCase("${Buffer.from(payload).toString('base64')}", node: Self.node)\n    }`,
    );
}

const node = Buffer.from(process.execPath).toString('base64');
process.stdout.write(`// Generated from the Node test definitions.\n`
    + `final class WorkerCaseTests: WorkerTestCase {\n    private static let node = "${node}"\n\n`
    + `${declarations.join('\n\n')}\n}\n`);
