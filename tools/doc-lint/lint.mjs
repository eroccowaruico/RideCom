import { execFileSync } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createLinter, loadTextlintrc } from 'textlint';
import japaneseWriting from 'textlint-rule-preset-ja-technical-writing';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const targets = ['docs/*.md', '.agents/skills/*.md', 'README.md', 'AGENTS.md'];
const git = (...args) => execFileSync('git', args, {
    cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024
});

// Japanese sentence rules visit paragraphs. Give each table cell its own paragraph,
// using the existing inline nodes so that code, links and source positions survive.
function includeCells(node, tableLines) {
    for (const child of node.children ?? []) includeCells(child, tableLines);
    if (node.type !== 'TableCell' || !node.children.length) return;
    tableLines.add(node.loc.start.line);
    const first = node.children[0];
    const last = node.children.at(-1);
    const range = [first.range[0], last.range[1]];
    node.children = [{
        type: 'Paragraph', children: node.children, range,
        loc: { start: first.loc.start, end: last.loc.end },
        raw: node.raw.slice(range[0] - node.range[0], range[1] - node.range[0])
    }];
}

// An API identifier or a file path is one reference in a sentence. Keep the
// source range for diagnostics. Only the sentence-length rule uses this view.
function sentenceChildren(children) {
    return children.flatMap(node => {
        if (node.type === 'Strong' || node.type === 'Emphasis') {
            return sentenceChildren(node.children);
        }
        if (node.type === 'Code' && isTechnicalReference(node.value)) {
            return [{...node, value: 'X'}];
        }
        return [node];
    });
}

function isTechnicalReference(value) {
    // A single code identifier, file path or URL. Ordinary quoted prose,
    // including Japanese text placed in backticks, still counts in full.
    if (/\s/u.test(value)) return false;
    if (/^(?:[a-z][a-z0-9]*-)+[0-9]{8,}$/u.test(value) || /^test[A-Z]\w+…$/u.test(value)) return true;
    if (/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/iu.test(value)) return true;
    return /^(?:https?:\/\/|(?:[.]{0,2}\/)?(?:[\w.@-]+\/)+)[^\s]+$/u.test(value)
        || /^[a-zA-Z_$][a-zA-Z0-9_$.:-]*$/u.test(value) &&
            /[a-z][A-Z]|[._:$]|[A-Z]{2}[a-z]/u.test(value);
}

function useRenderedSentence(rule) {
    if (rule.ruleId !== 'ja-technical-writing/sentence-length') return rule;
    return {...rule, rule(context, options) {
        const handlers = rule.rule(context, options);
        const paragraph = context.Syntax.Paragraph;
        return {...handlers, [paragraph](node) {
            const rendered = Object.create(node, {children: {value: sentenceChildren(node.children), enumerable: true}});
            return handlers[paragraph](rendered);
        }};
    }};
}

// Quoted UI strings keep their original register. Preserve UTF-16 offsets so
// diagnostics outside a quotation still point to the original source.
function maskJapaneseQuotes(text) {
    const stack = [];
    const ranges = [];
    for (let i = 0; i < text.length; i++) {
        const char = text[i];
        if (char === '「' || char === '『') {
            stack.push({at: i, end: char === '「' ? '」' : '』'});
        } else if (stack.length && char === stack.at(-1).end) {
            const {at} = stack.pop();
            if (!stack.length) ranges.push([at, i + 1]);
        }
    }
    for (const [start, end] of ranges) {
        text = text.slice(0, start) + text.slice(start, end).replace(/[^\r\n]/g, ' ') + text.slice(end);
    }
    return text;
}

function useNarrativeRegister(rule) {
    if (rule.ruleId !== 'ja-technical-writing/no-mix-dearu-desumasu') return rule;
    return {...rule, rule(context, options) {
        const proseContext = Object.create(context, {
            getSource: {value: node => maskJapaneseQuotes(context.getSource(node))}
        });
        return rule.rule(proseContext, options);
    }};
}

export async function markdownLinter() {
    const config = await loadTextlintrc({configFilePath: path.join(here, '.textlintrc.json')});
    const {rules, plugins} = config.toKernelOptions();
    const enabled = new Set(rules.filter(rule => rule.options !== false).map(rule => rule.ruleId));
    if (Object.keys(japaneseWriting.rules).some(name => !enabled.has('ja-technical-writing/' + name))) {
        throw new Error('Missing Japanese rules');
    }
    const markdown = plugins.find(p => p.pluginId === '@textlint/textlint-plugin-markdown');
    class TableMarkdown extends markdown.plugin.Processor {
        tableLines = new Set();
        longPress = new Set();

        processor(ext) {
            const tableLines = this.tableLines;
            const parser = super.processor(ext);
            const longPress = this.longPress;
            return {...parser, preProcess(text, name) {
                longPress.clear();
                for (const match of text.matchAll(/長押しし[てた]/gu)) longPress.add(match.index + 3);
                tableLines.clear();
                const tree = parser.preProcess(text, name);
                includeCells(tree, tableLines);
                return tree;
            }, postProcess(messages, name) {
                // A status or column label can stand alone without a Japanese period.
                return parser.postProcess(messages.filter(m => {
                    if (tableLines.has(m.line) && m.ruleId === 'ja-technical-writing/ja-no-mixed-period') return false;
                    // The tokenizer counts the noun ending and the verb in 長押しして twice.
                    if (m.ruleId === 'ja-technical-writing/ja-no-successive-word' &&
                        longPress.has(m.index)) return false;
                    return true;
                }), name);
            }};
        }
    }
    const descriptor = config.shallowMerge({
        rules: rules.map(useRenderedSentence).map(useNarrativeRegister),
        plugins: [{...markdown, plugin: {Processor: TableMarkdown}}]
    });
    return createLinter({descriptor, cwd: here});
}

export async function findings(linter, text, name) {
    const {messages} = await linter.lintText(text, name);
    return messages.map(m => ({
        line: m.line, column: m.column, rule: m.ruleId, severity: m.severity
    }));
}

async function run(args) {
    if (args.length && !(args.length === 1 && args[0] === '--all')) {
        throw new Error('Unexpected argument');
    }
    const files = git('ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', ...targets)
        .split('\0').filter(Boolean);
    const linter = await markdownLinter();
    let errors = 0;
    let warnings = 0;
    for (const name of [...new Set(files)].sort()) {
        const file = path.join(root, name);
        const stat = await lstat(file).catch(e => { if (e.code !== 'ENOENT') throw e; });
        if (!stat) continue;
        if (!stat.isFile() || await realpath(file) !== file) throw new Error('Unsupported document type');
        const issues = await findings(linter, await readFile(file, 'utf8'), name);
        for (const {line, column, rule, severity} of issues) {
            const warning = severity === 1;
            if (warning) warnings++;
            else errors++;
            // Keep text and free-form diagnostics out of validation logs.
            const label = process.stdout.isTTY ? JSON.stringify(name) : 'Markdown';
            console.log(label + ':' + line + ':' + column + (warning ? ' 要確認 ' : ' 要修正 ') + rule);
        }
    }
    console.log('日本語技術文書の検査結果　要修正 ' + errors + '件、要確認 ' + warnings + '件');
    return errors ? 1 : 0;
}

if (process.argv[1] && await realpath(process.argv[1]).catch(() => null) === fileURLToPath(import.meta.url)) {
    try {
        process.exitCode = await run(process.argv.slice(2));
    } catch {
        console.error('文書検査を実行できません。Node.jsの版、固定した依存関係、Gitの作業フォルダを確認してください。');
        process.exitCode = 2;
    }
}
