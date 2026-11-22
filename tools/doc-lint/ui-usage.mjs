import sourcePaths from './targets.json' with {type: 'json'};
import { execFileSync } from 'node:child_process';
import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parse } from 'parse5';
import { usageFindings } from './japanese-usage.mjs';

const targets = sourcePaths.ui;

// Read JSON tokens in source order so identical translations in different locales
// retain their own diagnostic location. JSON.parse validates the complete input.
function catalogText(source) {
    const catalog = JSON.parse(source);
    if (typeof catalog.sourceLanguage !== 'string' || !catalog.strings || Array.isArray(catalog.strings) ||
        typeof catalog.strings !== 'object') throw new Error('Invalid string catalog');
    const japanese = locale => /^ja(?:[-_]|$)/i.test(locale);
    const text = [];
    const tokens = source.matchAll(/"(?:\\[\s\S]|[^"\\])*"|[{}[\]:,]|[^\s{}[\]":,]+/g);
    function visit(token, keys) {
        const literal = token[0];
        if (literal === '{') {
            let key = tokens.next().value;
            while (key[0] !== '}') {
                const name = JSON.parse(key[0]);
                if (keys.length === 1 && keys[0] === 'strings' && japanese(catalog.sourceLanguage)) {
                    text.push({text: name, index: key.index});
                }
                tokens.next(); // colon
                visit(tokens.next().value, [...keys, name]);
                key = tokens.next().value;
                if (key[0] === ',') key = tokens.next().value;
            }
        } else if (literal === '[') {
            let item = tokens.next().value;
            while (item[0] !== ']') {
                visit(item, [...keys, '[]']);
                item = tokens.next().value;
                if (item[0] === ',') item = tokens.next().value;
            }
        } else if (literal.startsWith('"') && keys[0] === 'strings' && keys[2] === 'localizations' &&
            japanese(keys[3]) && (keys.slice(-2).join('/') === 'stringUnit/value' ||
            keys.slice(-3).join('/') === 'stringSet/values/[]')) {
            text.push({text: JSON.parse(literal), index: token.index});
        }
    }
    visit(tokens.next().value, []);
    return text;
}

const blocks = new Set('address article aside blockquote br button caption dd div dl dt fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr label li main nav ol option p pre section table td th title tr ul'.split(' '));
const hiddenTags = new Set(['script', 'style', 'template']);
const wordingAttributes = new Set(['alt', 'aria-label', 'aria-description', 'aria-valuetext',
    'aria-roledescription', 'title', 'placeholder', 'label']);

function htmlText(source) {
    const entries = [];
    let text = '';
    let start = 0;
    function flush() {
        if (text.trim()) entries.push({text, index: start});
        text = '';
    }
    function visit(node) {
        if (hiddenTags.has(node.tagName) || node.attrs?.some(a => a.name === 'hidden')) return;
        const loc = node.sourceCodeLocation;
        if (node.nodeName === '#text') {
            if (!text) start = loc.startOffset;
            text += node.value;
            return;
        }
        const block = blocks.has(node.tagName);
        if (block) flush();
        const input = node.tagName === 'input' && node.attrs.some(a =>
            a.name === 'type' && /^(?:submit|reset|button)$/i.test(a.value));
        for (const attr of node.attrs ?? []) {
            if (wordingAttributes.has(attr.name) || (input && attr.name === 'value')) {
                entries.push({text: attr.value, index: loc.attrs[attr.name].startOffset});
            }
        }
        for (const child of node.childNodes ?? []) visit(child);
        if (block) flush();
    }
    visit(parse(source, {sourceCodeLocationInfo: true}));
    flush();
    return entries;
}

// Scan literals rather than Swift identifiers and comments. Follow interpolation
// expressions to find any embedded literal, including both arms of a conditional.
function swiftText(source) {
    const entries = [];
    let i = 0;
    function comments() {
        if (source.startsWith('//', i)) {
            const end = source.indexOf('\n', i + 2);
            i = end < 0 ? source.length : end;
            return true;
        }
        if (!source.startsWith('/*', i)) return false;
        let depth = 1;
        i += 2;
        while (i < source.length && depth) {
            if (source.startsWith('/*', i)) { depth++; i += 2; }
            else if (source.startsWith('*/', i)) { depth--; i += 2; }
            else i++;
        }
        return true;
    }
    function string() {
        const start = i;
        while (source[i] === '#') i++;
        const hashes = source.slice(start, i);
        if (source[i] !== '"') return false;
        const quote = source.startsWith('"""', i) ? '"""' : '"';
        i += quote.length;
        const end = quote + hashes;
        const escapePrefix = `\\${hashes}`;
        let text = '';
        while (i < source.length && !source.startsWith(end, i)) {
            if (!source.startsWith(escapePrefix, i)) {
                text += source[i++];
                continue;
            }
            i += escapePrefix.length;
            const c = source[i++];
            if (c === '(') {
                code(true);
                text += '%@';
            } else if (c === 'u' && source[i] === '{') {
                const close = source.indexOf('}', i + 1);
                const hex = source.slice(i + 1, close);
                if (close < 0 || !/^[\da-f]{1,8}$/i.test(hex)) throw new Error('Invalid Swift escape');
                text += String.fromCodePoint(parseInt(hex, 16));
                i = close + 1;
            } else {
                text += ({n: '\n', r: '\r', t: '\t'})[c] ?? c;
            }
        }
        if (!source.startsWith(end, i)) throw new Error('Unterminated string');
        i += end.length;
        entries.push({text, index: start});
        return true;
    }
    function code(interpolation = false) {
        let depth = interpolation ? 1 : 0;
        while (i < source.length) {
            if (comments()) continue;
            if (source[i] === '"' || source[i] === '#') {
                if (string()) continue;
            }
            const c = source[i++];
            if (interpolation && c === '(') depth++;
            if (interpolation && c === ')' && --depth === 0) return;
        }
    }
    code();
    return entries;
}

export function uiTexts(name, source) {
    if (name.endsWith('.xcstrings')) return catalogText(source);
    if (name.endsWith('.html')) return htmlText(source);
    const literals = swiftText(source);
    // In an Apple .strings file each key is followed by its translated value.
    return name.endsWith('.strings') ? literals.filter((_, i) => i % 2 === 1) : literals;
}

export async function checkUIUsage(root) {
    const files = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard',
        '--', ...targets], {cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']}).split('\0').filter(Boolean);
    let errors = 0;
    let warnings = 0;
    for (const name of new Set(files)) {
        const file = path.join(root, name);
        const stat = await lstat(file).catch(e => { if (e.code !== 'ENOENT') throw e; });
        if (!stat) continue;
        if (!stat.isFile() || await realpath(file) !== file) throw new Error('Unsupported wording source');
        const bytes = await readFile(file);
        let encoding = 'utf-8';
        if (name.endsWith('.strings') && bytes[0] === 0xff && bytes[1] === 0xfe) encoding = 'utf-16le';
        if (name.endsWith('.strings') && bytes[0] === 0xfe && bytes[1] === 0xff) encoding = 'utf-16be';
        const source = new TextDecoder(encoding, {fatal: true}).decode(bytes);
        for (const entry of uiTexts(name, source)) {
            for (const finding of usageFindings(entry.text)) {
                const warning = finding.severity === 1;
                if (warning) warnings++;
                else errors++;
                const label = process.stdout.isTTY ? JSON.stringify(name) : 'UI';
                const line = source.slice(0, entry.index).split('\n').length;
                const advice = process.stdout.isTTY ? ` ${finding.message}` : '';
                console.log(`${label}:${line}${warning ? ' 要確認 ' : ' 要修正 '}${finding.rule}${advice}`);
            }
        }
    }
    return {errors, warnings};
}

if (process.argv[1] && await realpath(process.argv[1]).catch(() => null) === fileURLToPath(import.meta.url)) {
    try {
        const root = fileURLToPath(new URL('../../', import.meta.url));
        const {errors, warnings} = await checkUIUsage(root);
        console.log(`画面の日本語の検査結果　要修正 ${errors}件、要確認 ${warnings}件`);
        process.exitCode = errors ? 1 : 0;
    } catch {
        console.error('画面の日本語を検査できません。対象の形式と依存関係を確認してください。');
        process.exitCode = 2;
    }
}
