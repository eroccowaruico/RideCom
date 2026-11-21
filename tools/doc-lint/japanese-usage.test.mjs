import assert from 'node:assert/strict';
import test from 'node:test';
import { usageFindings } from './japanese-usage.mjs';
import { markdownLinter, findings } from './lint.mjs';

test('distinguish the meaning of each occurrence within a sentence', () => {
    for (const [bad, good] of [
        ['対象・版・条件を記録する', '第3版を読む'],
        ['CIが緑になった', '接続中は緑色の点を表示する'],
        ['テストが赤になった', 'テスト画面の赤いボタンを押す'],
        ['通知を配送する', '荷物を配送する'],
        ['仕様書を正本にする', '判決書の正本を送達する'],
        ['AIが仕様の採否を裁定する', '著作権法に基づく裁定を申請する'],
        ['赤いテストを直す', '校正刷りの版を確認する'],
        ['検証はグリーン', 'データベースの正本と副本を同期する'],
        ['緑になったのでマージする', 'JPドメイン名紛争の裁定を読む'],
        ['検証を閉じる', '検証画面を閉じる'],
        ['変更を着地させる', '飛行機を着地させる'],
    ]) {
        assert.ok(usageFindings(bad).some(i => i.severity === 2), bad);
        assert.deepEqual(usageFindings(good), [], good);
        assert.equal(usageFindings(`${good}。${bad}`).length, 1);
    }
    assert.equal(usageFindings('荷物を配送し、次に通知を配送する。')[0].index, 12);
});

test('textlint reads visible words across markup, tables and headings', async () => {
    const lint = await markdownLinter();
    const issues = await findings(lint, '# 手順の正本\n\n| 確認 | 結果 |\n|---|---|\n| **テスト**が緑 | [通知の配送](通知の配送.md) |\n\n```sh\necho 通知を配送する\n```', '例.md');
    const usage = issues.filter(i => i.rule.startsWith('ridecom-ja/'));
    assert.deepEqual(usage.map(i => [i.line,i.column]), [[1,6],[5,11],[5,19]]);
});

test('skill descriptions expose usage in the original source location', async () => {
    const lint = await markdownLinter();
    const issues = await findings(lint, '---\nname: example\ndescription: 通知を配送する\n---\n# 説明', 'SKILL.md');
    assert.deepEqual(issues.filter(i => i.rule.startsWith('ridecom-ja/')).map(i => i.line), [3]);
});
