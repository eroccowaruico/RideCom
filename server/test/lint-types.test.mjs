import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, copyFileSync, symlinkSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

test('type lint reports unsafe types and review candidates without printing source values', t => {
    const dir = mkdtempSync(join(tmpdir(), 'worker-type-lint-'))
    t.after(() => rmSync(dir, { recursive: true, force: true }))
    copyFileSync(new URL('../lint-types.mjs', import.meta.url), join(dir, 'lint-types.mjs'))
    symlinkSync(fileURLToPath(new URL('../node_modules', import.meta.url)), join(dir, 'node_modules'), 'dir')
    writeFileSync(join(dir, 'tsconfig.json'), JSON.stringify({compilerOptions: {strict: true, types: []}, files: ['input.ts']}))
    const input = join(dir, 'input.ts')
    const lint = (...args) => spawnSync(process.execPath, ['lint-types.mjs', ...args], {cwd: dir, encoding: 'utf8'})
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
