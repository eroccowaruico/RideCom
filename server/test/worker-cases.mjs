import { readdir, realpath } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { sep } from 'node:path';
import { pathToFileURL } from 'node:url';

let listingCount = 0;

export async function listWorkerCases(directory = new URL('./', import.meta.url)) {
    const root = pathToFileURL(await realpath(directory) + sep);
    const files = (await readdir(root, { withFileTypes: true }))
        .filter(file => file.isFile() && !file.name.startsWith('.') && file.name.endsWith('.test.mjs'))
        .map(file => file.name)
        .sort();
    const query = `?workerCases=${listingCount++}`;
    const registrar = new URL(`./support/case-registration.mjs${query}`, import.meta.url).href;
    const { beginRegistration, endRegistration } = await import(registrar);
    const source = file => new URL(encodeURIComponent(file) + query, root).href;
    const sources = new Set(files.map(source));
    const hooks = registerHooks({
        resolve(specifier, context, nextResolve) {
            if (specifier === 'node:test' && sources.has(context.parentURL)) {
                return { url: registrar, shortCircuit: true };
            }
            return nextResolve(specifier, context);
        },
    });
    const cases = [];
    try {
        for (const file of files) {
            beginRegistration(file);
            try {
                await import(source(file));
            } finally {
                cases.push(...endRegistration());
            }
        }
    } finally {
        hooks.deregister();
    }
    if (!cases.length) {
        throw new Error('No Worker test cases registered');
    }
    return cases;
}

if (import.meta.main) {
    listWorkerCases().then(cases => {
        process.stdout.write(`${JSON.stringify(cases)}\n`);
    }).catch(error => {
        console.error(error);
        process.exitCode = 1;
    });
}
