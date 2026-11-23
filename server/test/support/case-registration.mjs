import nativeTest, {
    after as nativeAfter, afterEach as nativeAfterEach, before as nativeBefore,
    beforeEach as nativeBeforeEach, describe as nativeDescribe,
} from 'node:test';

// Loaded instead of node:test only for the file being listed or individually selected.
let current;
const parents = [];

export function beginRegistration(file, selection) {
    current = { file, selection, cases: [], repeatedNames: new Map() };
}

export function endRegistration() {
    const cases = current.cases;
    current = undefined;
    return cases;
}

function registerTest(method, name, ...args) {
    if (typeof name !== 'string' || !name.trim()) {
        throw new TypeError('A Worker test case must have a nonempty name');
    }
    const names = [...parents, name];
    const path = JSON.stringify(names);
    const occurrence = (current.repeatedNames.get(path) ?? 0) + 1;
    current.repeatedNames.set(path, occurrence);
    current.cases.push({ file: current.file, names, occurrence });
    const selected = current.selection;
    if (selected && selected.occurrence === occurrence && JSON.stringify(selected.names) === path) {
        return method(name, ...args);
    }
}

function registerSuite(method, name, options, callback) {
    const inline = typeof options === 'function';
    const register = inline ? options : callback;
    if (typeof name !== 'string' || !name.trim() || typeof register !== 'function') {
        throw new TypeError('A Worker test suite must have a name and a registration callback');
    }
    if (register.constructor.name === 'AsyncFunction') {
        throw new TypeError('Declare Worker test cases synchronously inside their suites');
    }
    function registerChildren(...context) {
        parents.push(name);
        try {
            const result = register.apply(this, context);
            if (typeof result?.then === 'function') {
                throw new TypeError('Declare Worker test cases synchronously inside their suites');
            }
        } finally {
            parents.pop();
        }
    }
    const selected = current.selection;
    if (!selected) return registerChildren();
    const ancestors = [...parents, name];
    if (ancestors.length < selected.names.length && ancestors.every((part, index) => selected.names[index] === part)) {
        return inline ? method(name, registerChildren) : method(name, options, registerChildren);
    }
}

function wrappedRegistrations(register, native) {
    return Object.assign((...args) => register(native, ...args), {
        skip: (...args) => register(native.skip, ...args),
        todo: (...args) => register(native.todo, ...args),
        only: (...args) => register(native.only, ...args),
    });
}

export const test = wrappedRegistrations(registerTest, nativeTest);
export const describe = wrappedRegistrations(registerSuite, nativeDescribe);
export const it = test;
export const suite = describe;
export const before = (...args) => current.selection ? nativeBefore(...args) : undefined;
export const after = (...args) => current.selection ? nativeAfter(...args) : undefined;
export const beforeEach = (...args) => current.selection ? nativeBeforeEach(...args) : undefined;
export const afterEach = (...args) => current.selection ? nativeAfterEach(...args) : undefined;
export default test;
