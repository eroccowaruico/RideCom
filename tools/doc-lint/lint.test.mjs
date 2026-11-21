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

test('consistent specifications and instructions pass, while mixing styles is an error', async () => {
    const spec = 'この操作は任意である。\n\n既定の設定は有効である。';
    const manual = 'この操作は任意です。\n\n設定を開きます。';
    assert.deepEqual(await check(spec), []);
    assert.deepEqual(await check(manual), []);
    const issues = await check(spec + '\n\n設定を開きます。');
    assert.ok(issues.some(i => i.rule.endsWith('/no-mix-dearu-desumasu') && i.severity === 2));
});

test('uncertainty prompts review, while a repeated word still needs correction', async () => {
    const issues = await check('通信が遅れたのかもしれない。\n\nこのこの設定を使う。');
    assert.ok(issues.some(i => i.rule.endsWith('/ja-no-weak-phrase') && i.severity === 1));
    assert.ok(issues.some(i => i.rule.endsWith('/ja-no-successive-word') && i.severity === 2));
});

test('quoted questions, code, and inclusive table boundaries retain their original meaning', async () => {
    assert.deepEqual(await check('画面に「表示しますか？」または“Show the tab?”を表示する。'), []);
    assert.deepEqual(await check('> 設定を変更することができます。'), []);
    assert.deepEqual(await check('| 条件 | 結果 |\n|---|---|\n| `遅延 ≤ 120 ms` | 再生を続ける |'), []);
    const issues = await check('必ず押してください！');
    assert.ok(issues.some(i => i.rule.endsWith('/no-exclamation-question-mark') && i.severity === 2));
});

test('the preset still enforces the standard sentence length and comma limits', async () => {
    const sentence = length => '文'.repeat(length - 1) + '。';
    const lengthFindings = async n => (await check(sentence(n))).filter(i => i.rule.endsWith('/sentence-length'));
    assert.equal((await lengthFindings(100)).length, 0);
    assert.equal((await lengthFindings(101)).length, 1);
    assert.deepEqual(await check('音声、画像、文章、時刻、位置を確認する。'), []);
    const commas = await check('音声を受け取り、画像を開き、文章を読み、時刻を見て、位置を確認する。');
    assert.ok(commas.some(i => i.rule.endsWith('/max-ten') && i.severity === 2));
});
