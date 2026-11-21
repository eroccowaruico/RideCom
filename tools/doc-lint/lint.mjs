import { execFileSync } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createLinter, loadTextlintrc } from 'textlint';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
// The last shared revision before introducing this check. Keep it fixed across commits.
const adoption = '4dd04e8321335a41b3ed1c53bce1baadafcd8297';
const targets = ['docs/*.md', '.agents/skills/*.md', 'README.md', 'AGENTS.md'];
const git = (...args) => execFileSync('git', args, {
    cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 32 * 1024 * 1024
});
const names = (...args) => git(...args, '--', ...targets).split('\0').filter(Boolean);

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

export async function markdownLinter() {
    const config = await loadTextlintrc({configFilePath: path.join(here, '.textlintrc.json')});
    const {rules, plugins} = config.toKernelOptions();
    if (!rules.some(rule => rule.ruleId === 'ja-technical-writing/ja-no-redundant-expression')) {
        throw new Error('Missing Japanese rules');
    }
    const markdown = plugins.find(p => p.pluginId === '@textlint/textlint-plugin-markdown');
    class TableMarkdown extends markdown.plugin.Processor {
        tableLines = new Set();

        processor(ext) {
            const tableLines = this.tableLines;
            const parser = super.processor(ext);
            return {...parser, preProcess(text, name) {
                tableLines.clear();
                const tree = parser.preProcess(text, name);
                includeCells(tree, tableLines);
                return tree;
            }, postProcess(messages, name) {
                // A status or column label can stand alone without a Japanese period.
                return parser.postProcess(messages.filter(m =>
                    !(tableLines.has(m.line) && m.ruleId === 'ja-technical-writing/ja-no-mixed-period')
                ), name);
            }};
        }
    }
    const descriptor = config.shallowMerge({plugins: [{...markdown, plugin: {Processor: TableMarkdown}}]});
    return createLinter({descriptor, cwd: here});
}

async function findings(linter, text, name) {
    const lines = text.split('\n');
    const {messages} = await linter.lintText(text, name);
    return messages.map(m => ({
        line: m.line, column: m.column, rule: m.ruleId, severity: m.severity,
        key: JSON.stringify([m.ruleId, m.column, lines[m.line - 1]])
    }));
}

export async function addedFindings(linter, name, currentText, previousText) {
    const current = await findings(linter, currentText, name);
    if (!current.length || previousText === undefined) return current;
    const existing = new Map();
    for (const {key} of await findings(linter, previousText, name)) {
        existing.set(key, (existing.get(key) ?? 0) + 1);
    }
    return current.filter(({key}) => {
        const remaining = existing.get(key) ?? 0;
        if (!remaining) return true;
        existing.set(key, remaining - 1);
        return false;
    });
}

async function run(args) {
    if (args.length && !(args.length === 1 && args[0] === '--all')) {
        throw new Error('Unexpected argument');
    }
    const all = args.includes('--all');
    const files = all ? names('ls-files', '-z', '--cached', '--others', '--exclude-standard')
        : [...names('diff', '--no-renames', '--name-only', '--diff-filter=AMT', '-z', adoption),
           ...names('ls-files', '-z', '--others', '--exclude-standard')];
    const original = all ? new Set() : new Set(git('ls-tree', '-r', '-z', '--name-only', adoption, '--', 'docs', '.agents/skills', 'README.md', 'AGENTS.md').split('\0'));
    const linter = await markdownLinter();
    let errors = 0;
    let warnings = 0;
    for (const name of [...new Set(files)].sort()) {
        const file = path.join(root, name);
        const stat = await lstat(file).catch(e => { if (e.code !== 'ENOENT') throw e; });
        if (!stat) continue;
        if (!stat.isFile() || await realpath(file) !== file) throw new Error('Unsupported document type');
        const previous = original.has(name) ? git('show', adoption + ':' + name) : undefined;
        const issues = await addedFindings(linter, name, await readFile(file, 'utf8'), previous);
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

if (process.argv[1] && await realpath(process.argv[1]) === fileURLToPath(import.meta.url)) {
    try {
        process.exitCode = await run(process.argv.slice(2));
    } catch {
        console.error('文書検査を実行できません。Node.jsの版、固定した依存関係、Gitの履歴を確認してください。');
        process.exitCode = 2;
    }
}
