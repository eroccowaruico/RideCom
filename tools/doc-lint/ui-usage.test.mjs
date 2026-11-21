import assert from 'node:assert/strict';
import test from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, realpath, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {checkUIUsage, uiTexts} from './ui-usage.mjs';

const values = (name, source) => uiTexts(name, source).map(entry => entry.text);

test('catalogs cover Japanese keys, plurals, substitutions and multiple shortcut phrases', () => {
    const catalog = {
        sourceLanguage: 'ja',
        strings: {
            '表示する文': {comment: '翻訳担当への指示', localizations: {
                'ja-JP': {
                    stringUnit: {value: '翻訳'},
                    variations: {plural: {one: {stringUnit: {value: '単数形'}}}},
                    substitutions: {count: {variations: {plural: {other: {stringUnit: {value: '複数形'}}}}}},
                    stringSet: {values: ['候補1', '候補2']}
                },
                en: {stringUnit: {value: '別の言語'}}
            }}
        }
    };
    const source = JSON.stringify(catalog, null, 2);
    assert.deepEqual(values('Localizable.xcstrings', source), ['表示する文', '翻訳', '単数形', '複数形', '候補1', '候補2']);
    assert.equal(uiTexts('Localizable.xcstrings', source)[3].index, source.indexOf('"複数形"'));
    catalog.sourceLanguage = 'en';
    assert.equal(values('AppShortcuts.xcstrings', JSON.stringify(catalog)).includes('表示する文'), false);
    assert.throws(() => values('Invalid.xcstrings', '{'));
});

test('HTML checks visible inline text and spoken labels without reading script or style content', () => {
    const html = '<p>通<strong>知</strong>を送る</p><input title="説明" aria-label="通&#x77e5;" placeholder="入力">' +
        '<input type=submit value="開始"><img alt="説明図"><label hidden>隠し項目</label>' +
        '<style>a{color:red}</style><script>const s="内部";</script>';
    assert.deepEqual(values('mock.html', html), ['通知を送る', '説明', '通知', '入力', '開始', '説明図']);
});

test('Swift quotes, interpolation, nested comments and multiline raw strings retain the visible text', () => {
    const swift = [
        '// Text("無視する")',
        '/* "コメント" /* "入れ子" */ */',
        'Text("通\\u{77E5}を\\(ready ? "送る" : "待つ")")',
        'let raw = #"「通知」の\\#(person)"#',
        'let multiple = """\n通知が\n届いた\n"""'
    ].join('\n');
    assert.deepEqual(values('View.swift', swift), ['送る', '待つ', '通知を%@', '「通知」の%@', '\n通知が\n届いた\n']);
    assert.deepEqual(values('ja.lproj/InfoPlist.strings', '"識別子" = "マイクを使います";'), ['マイクを使います']);
});

test('the same rule blocks catalog, Swift, HTML attributes, and permission prompts in Git scope', async t => {
    const root = await realpath(await mkdtemp(path.join(tmpdir(), 'ridecom-ui-usage-')));
    t.after(() => rm(root, {recursive: true, force: true}));
    execFileSync('git', ['init', '-q', root]);
    const source = '仕様の正本を確認する';
    const files = {
        'RideIntercomWatch/View.swift': 'Text("' + source + '") // 仕様の正本',
        'RideIntercomWidgets/Widget.swift': 'Text("正本は規約にある")',
        'RideIntercom/packages/A/Tests/Sample.swift': 'let fixture = "仕様の正本"',
        'docs/design/preview.html': '<button aria-label="' + source + '">開く</button><script>正本</script>',
        'RideIntercom/ja.lproj/InfoPlist.strings': '"NSExample" = "' + source + '";',
        'RideIntercom/Localizable.xcstrings': JSON.stringify({sourceLanguage: 'en', strings: {s: {
            comment: source, localizations: {en: {stringUnit: {value: source}},
                ja: {substitutions: {n: {variations: {plural: {other: {stringUnit: {value: source}}}}}}}}
        }}})
    };
    for (const [name, contents] of Object.entries(files)) {
        const file = path.join(root, name);
        await mkdir(path.dirname(file), {recursive: true});
        await writeFile(file, name.endsWith('.strings') ? Buffer.from('\ufeff' + contents, 'utf16le') : contents);
    }
    const output = t.mock.method(console, 'log', () => {});
    assert.deepEqual(await checkUIUsage(root), {errors: 5, warnings: 0});
    assert.equal(output.mock.calls.length, 5);
    for (const call of output.mock.calls) {
        const [line] = call.arguments;
        assert.match(line, /要修正 ridecom-ja\/document-authority(?: |$)/u);
        assert.ok(!line.includes(source));
        if (!process.stdout.isTTY) assert.match(line, /^UI:\d+ /u);
    }
});
