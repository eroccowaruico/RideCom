import assert from 'node:assert/strict';
import test from 'node:test';
import { markdownLinter, addedFindings } from './lint.mjs';

const linter = await markdownLinter();
const redundant = '設定を変更することができます。';
const clear = '設定を変更できます。';
const check = (text, previous) => addedFindings(linter, 'fixture.md', text, previous);

test('paragraphs and table cells use Japanese rules and report the source line', async () => {
    const table = '| 状態 | 結果 |\n|---|---|\n| 使用中 | ';
    const issues = await check(table + redundant + ' |\n\n' + redundant);
    assert.deepEqual(issues.map(issue => issue.line), [3, 5]);
    assert.ok(issues.every(issue => issue.rule.endsWith('/ja-no-redundant-expression')));
    assert.deepEqual(await check(table + clear + ' |'), []);
    assert.deepEqual(await check('```text\n' + redundant + '\n```'), []);
});

test('moving existing text is allowed, duplicating a finding or changing its line is checked', async () => {
    assert.deepEqual(await check('# 仕様\n\n' + redundant, redundant), []);
    assert.equal((await check(redundant + '\n\n' + redundant, redundant)).length, 1);
    assert.equal((await check('通話の' + redundant, redundant)).length, 1);
    assert.deepEqual(await check(clear, redundant), []);
});
