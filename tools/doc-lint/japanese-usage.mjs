// A rule describes one meaning. Its exception is tested at the same occurrence,
// so an ordinary use earlier in a sentence cannot excuse a different use later.
const rules = [
    {
        id: 'document-authority', word: /正本/gu,
        before: /(?:判決書?|公正証書|裁判書|審判書|訴状|調書|命令書|契約書|公文書|データベース)(?:の|の原本と)?$/u,
        after: /^(?:と謄本|及び謄本|の送達|を送達|を交付)/u,
        advice: 'どの文書に何を記録し、判断が食い違ったときにどれを参照するかを書いてください。',
    },
    {
        id: 'decision-maker', word: /裁定/gu,
        before: /(?:JPドメイン名紛争の|著作権法に基づく|厚生労働大臣の|文化庁長官の|仲裁(?:人|機関)の|紛争処理(?:機関)?の|パネルの|年金の|スポーツ仲裁の|紛争処理手続の)$/u,
        after: /^(?:取引|委員会|申請|の謄本|による著作物の利用)/u,
        advice: '誰が何を根拠に決めるかを書いてください。制度上の決定なら制度名を添えてください。',
    },
    {
        id: 'message-delivery', word: /配送/gu,
        before: /(?:荷物|商品|小包|宅配便|貨物|郵便物|注文品|電子メール|メール|ログ)(?:の|を|が|は)?$/u,
        after: /^(?:業者|業務を担う運送|トラック|伝票|員|ドライバー)/u,
        advice: '送り出した段階、サービスが受け付けた段階、相手に届いた段階のうち、記録で確かめたことを書いてください。',
    },
    {
        id: 'test-result', word: /赤|緑|グリーン|レッド/gu,
        applies(before, after) {
            if (/^(?:字|外線|道|茶|十字|地|み|色|い(?:ボタン|印|点|文字|線|枠|表示)|の(?:ボタン|印|点|文字|線|枠|アイコン|チェックマーク))/u.test(after)) return false;
            return /(?:テスト|検査|検証|試験|CI|ビルド|回帰|結果|全件|すべて|全部|全て)(?:が|は|を|も|で|の|:|：|\s)*$/iu.test(before)
                || /^(?:(?:い|の)?テスト|から(?:赤|緑)|→(?:赤|緑)|になった(?:ので|ら)(?:マージ|統合)|を先に作ってから(?:緑|グリーン)に|のまま(?:通す|マージ|進む)|なら(?:合格|成功|マージ))/u.test(after)
                || /(?:^|[、。\s])(?:赤→|緑→)$/u.test(before);
        },
        advice: 'どの検査に合格したか、何が失敗したかを書いてください。画面の色を伝える場合は対象を示してください。',
    },
    {
        id: 'version-of-what', word: /(?:(?:依存|最低|稼働|対象|比較|影響|正常|基準|埋込|lockfile|使用)版|版)/gu,
        applies(before, after, word) {
            if (word !== '版') return true;
            if (/^(?:画|権|元|木|下|型|面|数|刷|籍|行)/u.test(after)) return false;
            if (/(?:出版|絶|初|復刻|再|第[一二三四五六七八九十百〇零\d０-９]+|[0-9０-９]+(?:年|月|日)?|英語|日本語|簡易|体験|試用|評価|製品|正式|改訂|修正|増補|文庫|新版|旧|最終|開発|ベータ|公開|最新版?|対応|更新|Windows|Linux|Android|Apple Watch|iOS|macOS|iPadOS|watchOS|Web|アプリ|ウェブ|ストア|電子|印刷|書籍|ソフトウェア|プレビュー)$/iu.test(before)) return false;
            if (/[\p{Script=Han}A-Za-z]$/u.test(before) && !/の$/u.test(before)) return false;
            return !/(?:書籍|刊行物|書物|教科書|小説|校正刷り|木版画)(?:の|の旧い|の新しい)$/u.test(before);
        },
        advice: 'アプリのバージョン、保存形式の番号、文書の改訂など、何が違うのかを明示してください。',
    },
    {
        id: 'unfinished-action',
        word: /(?:差分|作業|検証|E2E|回帰|節目|主軸|課題|単位|判断|残件|不足分|契約|確認|証拠|受入条件|コミット|commit)(?:まで|ごとに|を|で|として|までを|を先に)閉じ(?:る|た|て|ず|られ|、|。)/gu,
        advice: '何を実装・比較・確認したら作業を終えられるかを書いてください。',
    },
    {
        id: 'translated-metaphor',
        word: /(?:変更|修正|結論|議論|実装)(?:を|が)着地(?:させ|する|した)|(?:判断|責務|合意|仕様)を握(?:る|った|り)|(?:依頼|判断|課題)を刈り取(?:る|った)|(?:実装|作業)をブロック解除する|(?:唯一の真実の源|信頼できる唯一の真実)|(?:責務|判断権)を所有する|(?:タスク|議論)をドライブする|(?:機能|変更)をシップする/gu,
        advice: 'この場面で誰が何を決めるか、何を終えるか、何を再開するかを具体的に書いてください。',
    },
];

export const usageRuleIds = rules.map(rule => 'ridecom-ja/' + rule.id);

export function usageFindings(text) {
    const issues = [];
    for (const rule of rules) {
        for (const match of text.matchAll(rule.word)) {
            const {index} = match;
            const length = match[0].length;
            const before = text.slice(Math.max(0, index - 48), index);
            const after = text.slice(index + length, index + length + 48);
            if (rule.before?.test(before) || rule.after?.test(after)) continue;
            if (rule.applies && !rule.applies(before, after, match[0])) continue;
            issues.push({index, length, rule: 'ridecom-ja/' + rule.id, message: rule.advice, severity: 2});
        }
    }
    return issues.sort((a, b) => a.index - b.index);
}

// Keep the text readers see and a map to its original Markdown positions.
// A formatted label participates in its sentence; a URL or command does not.
function visibleText(node) {
    const parts = [];
    const offsets = [];
    function append(value, start) {
        parts.push(value);
        for (let i = 0; i < value.length; i++) offsets.push(start + i);
    }
    function visit(child) {
        if (child.type === 'yaml') {
            // Skill metadata contains reader-facing Japanese in its description.
            const description = /^description:[ \t]*(.*(?:\n[ \t]+.*)*)/mu.exec(child.raw);
            if (description) append(description[1], child.range[0] + description.index +
                description[0].length - description[1].length);
        } else if (child.type === 'Str') {
            append(child.raw, child.range[0]);
        } else if (child.type === 'Code') {
            // References and commands must retain their exact spelling.
            const code = child.value;
            if (/\p{Script=Hiragana}|\p{Script=Katakana}|\p{Script=Han}/u.test(code) &&
                !/[\/\\#]|\.[a-z0-9]{1,8}$/iu.test(code)) {
                append(code, child.range[0] + child.raw.indexOf(code));
            } else {
                append(' ', child.range[0]);
            }
        } else if (child.type === 'Break') {
            append(' ', child.range[0]);
        } else if (child.type === 'Image') {
            if (child.alt) append(child.alt, child.range[0] + 2);
        } else {
            for (const nested of child.children ?? []) visit(nested);
        }
    }
    visit(node);
    return {text: parts.join(''), offsets};
}

export function japaneseUsageRule(context) {
    function check(node) {
        // Historical quotations preserve the author's wording.
        for (let parent = node.parent; parent; parent = parent.parent) {
            if (parent.type === 'BlockQuote') return;
        }
        const {text, offsets} = visibleText(node);
        for (const issue of usageFindings(text)) {
            context.report(node, new context.RuleError(issue.rule + ' ' + issue.message, {
                index: offsets[issue.index] - node.range[0],
            }));
        }
    }
    return {[context.Syntax.Paragraph]: check, [context.Syntax.Header]: check, yaml: check};
}
