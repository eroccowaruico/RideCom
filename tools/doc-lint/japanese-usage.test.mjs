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

test('technical verbs specify the operation while literal actions keep their meaning', () => {
    for (const [phrase, literal] of [
        ['テストを最後まで走らせた', '自転車を最後まで走らせた'],
        ['コードをここで走らせてください', 'ここで模型の車を走らせてください'],
        ['検査が自動で走ります', '試験で自転車が走ります'],
        ['ジョブは夜間に走っている', '通勤で夜間に走っている'],
        ['走らせる', '道路を走る'],
        ['CIをもう一度回して', '音量つまみをもう一度回して'],
        ['APIを直接叩いた', 'ドアを直接叩いた'],
        ['要求をサーバーに投げる', '相手にボールを投げる'],
        ['ログを吐かない', '息を吐かない'],
        ['例外を握りつぶした', '紙を握りつぶした'],
        ['返されたエラーを飲み込む', '水を飲み込む'],
    ]) {
        assert.equal(usageFindings(phrase).length, 1, phrase);
        assert.deepEqual(usageFindings(literal), [], literal);
    }
});

test('use the historically common name for a displayed color, preserving other meanings', async () => {
    const colorRule = 'ridecom-ja/display-color';
    for (const text of ['警告ランプがレッドに点灯する', 'グリーンのボタンを押す',
        '文字色をレッドにする', '丸印をグリーンで表示する', '表示色はグリーン。', '結果をレッドで表示する']) {
        assert.deepEqual(usageFindings(text).map(i => i.rule), [colorRule], text);
    }
    for (const text of ['警告ランプが赤く点灯する', '緑のボタンを押す', '文字色を赤にする', '結果を赤で表示する',
        '配色名は「ダークレッド」', '製品名「レッド」のボタン', 'レッドカードを出す',
        'スレッドの表示', 'レッド→グリーン→リファクター']) {
        assert.deepEqual(usageFindings(text), [], text);
    }
    assert.equal(usageFindings('レッド')[0].severity, 1);
    assert.deepEqual(usageFindings('テストがレッド').map(i => i.rule), ['ridecom-ja/test-result']);
    const lint = await markdownLinter();
    const issues = await findings(lint, 'メインスレッドの表示。**グリーン**のボタンを押す。', '例.md');
    assert.equal(issues.filter(i => i.rule === colorRule).length, 1);
    const label = await findings(lint, 'レッド', '例.md');
    assert.equal(label.find(i => i.rule === 'ridecom-ja/color-label-context').severity, 1);
});
