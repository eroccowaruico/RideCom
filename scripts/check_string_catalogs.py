#!/usr/bin/env python3
"""Check that uncommitted String Catalog changes keep every existing translation.

Xcode syncs catalogs from extracted strings at build time: it adds, reorders,
marks entries stale and drops untranslated entries, but never deletes a
translation. A change that passes this check is a build output anyone may
commit; a lost translation needs its cause fixed instead.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path


def git(root: Path, *args: str) -> str:
    return subprocess.run(['git', *args], cwd=root, capture_output=True, text=True, check=True).stdout


def translations(data: object) -> set[tuple[str, str]]:
    if not isinstance(data, dict):
        raise TypeError('Expected a String Catalog object')
    source = data.get('sourceLanguage', 'en')
    strings = data.get('strings', {})
    if not isinstance(source, str) or not isinstance(strings, dict):
        raise TypeError('Invalid source language or strings')
    result = set()
    for key, entry in strings.items():
        if not isinstance(entry, dict) or not isinstance(entry.get('localizations', {}), dict):
            raise TypeError('Invalid localized string entry')
        result.update((key, language) for language in entry.get('localizations', {}) if language != source)
    return result

def check(root: Path, base: str) -> list[str]:
    changed = git(root, 'diff', '--name-only', '-z', base, '--', '*.xcstrings').split('\0')
    errors = []
    for name in filter(None, changed):
        path = root / name
        try:
            baseline = git(root, 'show', f'{base}:{name}')
        except subprocess.CalledProcessError:
            continue  # A new catalog cannot lose a committed translation.
        try:
            current = json.loads(path.read_text()) if path.is_file() else {}
            lost = translations(json.loads(baseline)) - translations(current)
        except (OSError, TypeError, ValueError) as error:
            errors.append(f'{name}: unreadable catalog ({error})')
            continue
        for key, language in sorted(lost):
            errors.append(f'{name}: lost {language} translation for {key!r}')
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--base', default='HEAD')
    args = parser.parse_args()
    errors = check(args.root, args.base)
    for error in errors:
        print(error)
    if errors:
        return 1
    print('String Catalogs: no committed translation lost')
    return 0


if __name__ == '__main__':
    sys.exit(main())
