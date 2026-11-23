import { registerHooks } from 'node:module';
import { pathToFileURL } from 'node:url';
import { beginRegistration } from './case-registration.mjs';

const selected = JSON.parse(process.argv[2]);
const source = pathToFileURL(process.argv[1]).href;
const registrar = new URL('./case-registration.mjs', import.meta.url).href;
beginRegistration(selected.file, selected);
registerHooks({
    resolve(specifier, context, nextResolve) {
        if (specifier === 'node:test' && context.parentURL === source) {
            return { url: registrar, shortCircuit: true };
        }
        return nextResolve(specifier, context);
    },
});
