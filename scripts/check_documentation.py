#!/usr/bin/env python3
"""Check local links, discoverability, backlog coverage, and Settings UI coverage."""
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

LINK = re.compile(r'\[[^\]\n]*\]\((<[^>]+>|[^\n)]+)\)')
UI_ID = re.compile(r'accessibilityIdentifier\s*[:(]\s*"([^"\\]+)"')


class DesignHTMLIDs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []

    def handle_starttag(self, tag, attrs):
        self.ids.extend(value for key, value in attrs if key == 'id' and value is not None)


def without_fences(text):
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


def check_backlog(backlog):
    details = backlog / '未実装課題.md'
    if not details.exists():
        return []
    index = backlog / 'README.md'
    prefix = 'docs/backlog/README.md'
    if not index.exists():
        return [f'{prefix}: missing backlog index']
    headings = re.findall(r'^## (.+)$', without_fences(details.read_text()), re.M)
    anchors = Counter(re.sub(r'[^\w -]', '', title.strip().lower()).replace(' ', '-') for title in headings)
    parts = re.split(r'^## (.+)\n', without_fences(index.read_text()), flags=re.M)
    sections = dict(zip(parts[1::2], parts[2::2]))
    errors, indexed = [], Counter()
    for section in ('着手順', '判断や再開を待つもの'):
        for row in sections.get(section, '').splitlines():
            if not row.startswith('|'):
                continue
            cells = [cell.strip() for cell in row.strip('|').split('|')]
            links = list(LINK.finditer(row))
            for link in links:
                destination = urlsplit(link[1].strip('<>'))
                if not destination.scheme and unquote(destination.path) == details.name:
                    indexed[unquote(destination.fragment)] += 1
            if section == '着手順' and links:
                classification = cells[1] if len(cells) > 1 else ''
                if classification not in ('改善', 'デザイン', '機能'):
                    errors.append(f'{prefix}: invalid backlog classification {classification or "(missing)"}')
    for anchor, count in sorted(anchors.items()):
        if count > 1:
            errors.append(f'docs/backlog/{details.name}: duplicate detail heading #{anchor}')
        if anchor not in indexed:
            errors.append(f'{prefix}: unindexed detail heading #{anchor}')
    for anchor, count in sorted(indexed.items()):
        if anchor not in anchors:
            errors.append(f'{prefix}: unknown detail heading #{anchor}')
        if count > 1:
            errors.append(f'{prefix}: duplicate index link #{anchor}')
    return errors


def check(root):
    root = root.resolve()
    documents = set((root / 'docs').rglob('*.md'))
    documents.add(root / 'README.md')
    for entry in ['AGENTS.md', 'CLAUDE.md', '.github/copilot-instructions.md']:
        if (root / entry).exists(): documents.add(root / entry)
    errors, edges = check_backlog(root / 'docs/backlog'), {}
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
        for match in LINK.finditer(text):
            destination = match.group(1).strip('<>')
            if urlsplit(destination).scheme or destination.startswith(('#', '/')):
                continue
            path = unquote(destination.split('#')[0])
            target = (document.parent / path).resolve()
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
    if errors: sys.exit(1)
    print('Documentation links, navigation, backlog coverage, design HTML IDs, empty directories, and Settings coverage: OK')
