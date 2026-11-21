import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, copyFileSync, symlinkSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

function lintFixture(t, types = []) {
    const dir = mkdtempSync(join(tmpdir(), 'worker-type-lint-'))
    t.after(() => rmSync(dir, { recursive: true, force: true }))
    copyFileSync(new URL('../lint-types.mjs', import.meta.url), join(dir, 'lint-types.mjs'))
    symlinkSync(fileURLToPath(new URL('../node_modules', import.meta.url)), join(dir, 'node_modules'), 'dir')
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({compilerOptions: {strict: true, types}, files: ['input.ts']}))
    const input = join(dir, 'input.ts')
    const lint = (...args) => spawnSync(process.execPath, ['lint-types.mjs', ...args], {cwd: dir, encoding: 'utf8'})
    return { input, lint }
}

test('type lint reports unsafe types and review candidates without printing source values', t => {
    const { input, lint } = lintFixture(t)
    const valid = 'export const caption = "// @ts-ignore private-fixture-marker" as const\n'
    writeFileSync(input, valid)
    assert.equal(lint().status, 0)
    const code = `// @ts-nocheck\n${valid}${[
        'type First = { id: string }',
        'type Second = { id: string }',
        'type Alias = First',
        'interface Copy extends First {}',
        'declare function accept(x: string): string',
        'function wrap(x: string) { return accept(x) }',
        'declare const raw: any',
        'const inferred = raw',
        'const unsafe = (raw as unknown) as string',
        'declare const optional: string | undefined',
        'const present = optional!',
        'const converted = String(present)',
        '// @ts-ignore',
        'accept(123)',
    ].join('\n')}\n`
    writeFileSync(input, code)
    const all = lint()
    assert.equal(all.status, 1, all.stderr)
    for (const rule of ['duplicate-shape', 'ts-nocheck', 'type-alias', 'forwarding-wrapper',
        'inferred-any', 'chained-assertion']) {
        assert.ok(all.stdout.includes(rule), rule)
    }
    assert.doesNotMatch(all.stdout, /private-fixture-marker/)
    assert.equal(lint('input.ts').status, 1)
    writeFileSync(input, valid)
    assert.equal(lint('input.ts').status, 0)
})

test('only Durable Object RPC and lifecycle entry points can delegate unchanged arguments', t => {
    const { input, lint } = lintFixture(t, ['@cloudflare/workers-types'])
    const lines = [
        "import { DurableObject as RuntimeObject } from 'cloudflare:workers'",
        'declare function accept(x: string): string',
        'export class Account extends RuntimeObject {',
        '    private readonly store = { read: accept }',
        '    read(x: string) { return this.store.read(x) }',
        '    alarm() { this.expire() }',
        '    private expire() {}',
        '    alias(x: string) { return (this.read)(x) }',
        '    private local(x: string) { return accept(x) }',
        '    protected helper(x: string) { return accept(x) }',
        '    static unrelated(x: string) { return accept(x) }',
        '}',
        'export class Room implements DurableObject {',
        '    fetch(_request: Request) { return new Response() }',
        '    webSocketError(ws: WebSocket) { this.webSocketClose(ws) }',
        '    webSocketClose(ws: WebSocket) { ws.close(1000) }',
        '    unrelated(x: string) { return accept(x) }',
        '}',
        'export class Unrelated {',
        '    alarm() { this.expire() }',
        '    private expire() {}',
        '}',
        'namespace Other { export class DurableObject {} }',
        'export class Lookalike extends Other.DurableObject {',
        '    read(x: string) { return accept(x) }',
        '}',
        'namespace Legacy { export interface DurableObject { alarm(): void } }',
        'export class LookalikeRoom implements Legacy.DurableObject {',
        '    alarm() { this.expire() }',
        '    private expire() {}',
        '}',
    ]
    writeFileSync(input, lines.join('\n'))
    const result = lint()
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, [
        ...[8, 9, 10, 11, 17, 20, 25, 29].map(line => `input.ts:${line}:5 review forwarding-wrapper`),
        'Worker structure: errors=0 review=8',
        '',
    ].join('\n'))
})

test('duplicate RPC delegation remains a review even when the published method names differ', t => {
    const { input, lint } = lintFixture(t, ['@cloudflare/workers-types'])
    const lines = [
        "import { DurableObject } from 'cloudflare:workers'",
        'class Store { read(value: string | number) { return value } }',
        'export class Account extends DurableObject {',
        '    private readonly primary = new Store()',
        '    private readonly secondary = new Store()',
        '    read(value: string) { return this.primary.read(value) }',
        '    readAgain(argument: string) { return this.primary["read"](argument) }',
        '    readNumeric(value: number) { return this.primary.read(value) }',
        '    readOther(value: string) { return this.secondary.read(value) }',
        '}',
    ]
    writeFileSync(input, lines.join('\n'))
    const result = lint()
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout, [
        'input.ts:7:5 review forwarding-wrapper',
        'Worker structure: errors=0 review=1',
        '',
    ].join('\n'))
})
