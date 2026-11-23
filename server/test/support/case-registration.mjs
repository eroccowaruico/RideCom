// Loaded only by the test-case listing process in place of node:test.
let current;
const parents = [];

export function beginRegistration(file) {
    current = { file, cases: [], repeatedNames: new Map() };
}

export function endRegistration() {
    const cases = current.cases;
    current = undefined;
    return cases;
}

function recordTest(name) {
    if (typeof name !== 'string' || !name.trim()) {
        throw new TypeError('A Worker test case must have a nonempty name');
    }
    const names = [...parents, name];
    const path = JSON.stringify(names);
    const occurrence = (current.repeatedNames.get(path) ?? 0) + 1;
    current.repeatedNames.set(path, occurrence);
    current.cases.push({ file: current.file, names, occurrence });
}

function recordSuite(name, options, callback) {
    const register = typeof options === 'function' ? options : callback;
    if (typeof name !== 'string' || !name.trim() || typeof register !== 'function') {
        throw new TypeError('A Worker test suite must have a name and a registration callback');
    }
    if (register.constructor.name === 'AsyncFunction') {
        throw new TypeError('Declare Worker test cases synchronously inside their suites');
    }
    parents.push(name);
    try {
        const result = register();
        if (typeof result?.then === 'function') {
            throw new TypeError('Declare Worker test cases synchronously inside their suites');
        }
    } finally {
        parents.pop();
    }
}

export const test = Object.assign(recordTest, { skip: recordTest, todo: recordTest, only: recordTest });
export const describe = Object.assign(recordSuite, { skip: recordSuite, todo: recordSuite, only: recordSuite });
export const it = test;
export const suite = describe;
export const before = () => undefined;
export const after = before;
export const beforeEach = before;
export const afterEach = before;
export default test;
