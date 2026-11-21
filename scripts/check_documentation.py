#!/usr/bin/env python3
"""Check local links, discoverability, backlog coverage, and Settings UI coverage."""
from __future__ import annotations

import re
import subprocess
import sys
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'\[[^\]\n]*\]\((<[^>]+>|[^\n)]+)\)')
UI_ID = re.compile(r'accessibilityIdentifier\s*[:(]\s*"([^"\\]+)"')


class DesignHTMLIDs(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.ids: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.ids.extend(value for key, value in attrs if key == 'id' and value is not None)


def without_fences(text: str) -> str:
    visible, fence = [], None
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif marker:
            fence = marker[1]
        else:
            visible.append(line)
    return ''.join(visible)


def heading_anchor(title: str) -> str:
    return re.sub(r'[^\w -]', '', title.strip().lower()).replace(' ', '-')


def check_backlog(backlog: Path) -> list[str]:
    issues = '未実装課題.md'
    design = '画面実装とデザイン見本の差分.md'
    if not (backlog / issues).exists():
        return []
    index = backlog / 'README.md'
    prefix = 'docs/backlog/README.md'
    if not index.exists():
        return [f'{prefix}: missing backlog index']
    anchors = Counter()
    for name, level in ((issues, 2), (design, 3)):
        document = backlog / name
        if document.exists():
            headings = re.findall(rf'^{level * "#"} (.+)$', without_fences(document.read_text()), re.MULTILINE)
            anchors.update((name, heading_anchor(title)) for title in headings)
    parts = re.split(r'^## (.+)\n', without_fences(index.read_text()), flags=re.MULTILINE)
    sections = dict(zip(parts[1::2], parts[2::2]))
    errors, indexed = [], Counter()
    for section in ('着手順', '判断や再開を待つもの'):
        for row in sections.get(section, '').splitlines():
            if not row.startswith('|'):
                continue
            cells = [cell.strip() for cell in row.strip('|').split('|')]
            if cells[0] == '課題' or re.fullmatch(r':?-{3,}:?', cells[0]):
                continue
            if len(cells) != 4 or not all(cells):
                errors.append(f'{prefix}: incomplete backlog row: {cells[0]}')
                continue
            link = LINK.fullmatch(cells[0])
            if not link:
                errors.append(f'{prefix}: missing backlog detail link: {cells[0]}')
                continue
            destination = urlsplit(link[1].strip('<>'))
            target = unquote(destination.path)
            if destination.scheme or target not in (issues, design) or not destination.fragment:
                errors.append(f'{prefix}: invalid backlog detail link: {link[1]}')
                continue
            indexed[target, unquote(destination.fragment)] += 1
            classification = cells[1]
            if classification not in ('改善', 'デザイン', '機能'):
                errors.append(f'{prefix}: invalid backlog classification {classification}')
            elif target == design and classification != 'デザイン':
                errors.append(f'{prefix}: invalid design classification {classification}')
    for (name, anchor), count in sorted(anchors.items()):
        if count > 1:
            errors.append(f'docs/backlog/{name}: duplicate detail heading #{anchor}')
        if (name, anchor) not in indexed:
            errors.append(f'{prefix}: unindexed detail heading #{anchor} in {name}')
    for (name, anchor), count in sorted(indexed.items()):
        if (name, anchor) not in anchors:
            errors.append(f'{prefix}: unknown detail heading #{anchor} in {name}')
        if count > 1:
            errors.append(f'{prefix}: duplicate index link #{anchor} in {name}')
    return errors


def check(root: Path) -> list[str]:
    root = root.resolve()
    backlog = root / 'docs/backlog'
    documents = set((root / 'docs').rglob('*.md'))
    documents.add(root / 'README.md')
    for entry in ['AGENTS.md', 'CLAUDE.md', '.github/copilot-instructions.md']:
        if (root / entry).exists(): documents.add(root / entry)
    errors, edges = check_backlog(backlog), {}
    backlog_anchors = {
        document: {
            heading_anchor(title)
            for title in re.findall(r'^#{1,6} (.+)$', without_fences(document.read_text()), re.MULTILINE)
        }
        for document in documents if document.parent == backlog
    }
    for sample in sorted((root / 'docs/design').rglob('*.html')):
        parser = DesignHTMLIDs()
        parser.feed(sample.read_text())
        for identifier, count in Counter(parser.ids).items():
            if count > 1:
                errors.append(f'{sample.relative_to(root)}: duplicate HTML id {identifier}')
    for directory in sorted((root / 'docs').rglob('*')):
        if directory.is_dir() and not any(directory.iterdir()):
            errors.append(f'{directory.relative_to(root)}: empty directory')
    for document in sorted(documents):
        text = without_fences(document.read_text())
        targets = set()
        historical = 'history' in document.relative_to(root).parts
        for match in LINK.finditer(text):
            destination = match.group(1).strip('<>')
            link = urlsplit(destination)
            if link.scheme or destination.startswith('/'):
                continue
            target = (document.parent / unquote(link.path)).resolve() if link.path else document
            if (not historical and target in backlog_anchors and link.fragment
                    and unquote(link.fragment) not in backlog_anchors[target]):
                errors.append(f'{document.relative_to(root)}: missing backlog heading {destination}')
            if not link.path:
                continue
            if not target.exists():
                errors.append(f'{document.relative_to(root)}: missing link {destination}')
            elif target in documents:
                targets.add(target)
        edges[document] = targets
        # Inline root-relative documentation paths are also references, except the migration ledger.
        if document.name != '文書整理記録.md':
            for reference in re.findall(r'`(docs/[^`\n]+)`', text):
                if '*' in reference:
                    exists = any(root.glob(reference))
                else:
                    exists = (root / reference).exists()
                if not exists:
                    errors.append(f'{document.relative_to(root)}: stale document path {reference}')
    reached, pending = set(), [root / 'README.md']
    while pending:
        item = pending.pop()
        if item in reached: continue
        reached.add(item)
        pending.extend(edges.get(item, set()) - reached)
    for document in sorted(documents - reached):
        errors.append(f'{document.relative_to(root)}: not reachable from README')
    ui = root / 'RideIntercom/UI/Settings'
    specification = root / 'docs/spec/App/UI/Settings.md'
    if ui.exists() and specification.exists():
        content = specification.read_text()
        identifiers = {identifier for source in ui.rglob('*.swift')
                       for identifier in UI_ID.findall(source.read_text())}
        for identifier in sorted(identifiers):
            if f'`{identifier}`' not in content:
                errors.append(f'Settings.md: undocumented UI identifier {identifier}')
    return errors


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    errors = check(root)
    for error in errors: print(error, file=sys.stderr)
    if not (root / 'tools/doc-lint/node_modules/textlint/package.json').is_file():
        sys.exit('文書検査の依存が未導入です。npm ci --prefix tools/doc-lint --ignore-scripts --no-audit --no-fund を実行してください。')
    try:
        lint = subprocess.run(['node', 'lint.mjs'], cwd=root / 'tools/doc-lint', check=False)
    except OSError:
        sys.exit('日本語の文書検査にはNode.jsが必要です。')
    if lint.returncode:
        print('文書検査の準備と指摘の直し方は、文書作成規約の「日本語の技術文書を検査する」を参照してください。', file=sys.stderr)
    if errors or lint.returncode: sys.exit(1)
    print('Documentation links, navigation, backlog coverage, design HTML IDs, empty directories, and Settings coverage: OK')
