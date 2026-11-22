"""Check the text and lint rules in the index selected by git commit."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

TOOL = 'tools/doc-lint'


def git(*args: str, data: bytes | None = None) -> bytes:
    return subprocess.check_output(['git', *args], input=data, stderr=subprocess.PIPE)


def paths(*args: str) -> list[str]:
    return [os.fsdecode(item) for item in git(*args).split(b'\0') if item]


def dependencies() -> Path:
    # Linked worktrees can share a prepared installation with the same lockfile.
    first = paths('worktree', 'list', '--porcelain', '-z')[0].removeprefix('worktree ')
    lock = git('show', f':{TOOL}/package-lock.json')
    for base in (Path.cwd(), Path(first)):
        folder = base / TOOL
        package_lock = folder / 'package-lock.json'
        modules = folder / 'node_modules'
        if ((modules / 'textlint/package.json').is_file() and package_lock.is_file()
                and package_lock.read_bytes() == lock):
            return modules.resolve()
    raise RuntimeError('npm ci --prefix tools/doc-lint --ignore-scripts --no-audit --no-fund を実行してください。')


def main() -> int:
    changed = ['diff', '--cached', '--name-only', '--no-renames', '-z']
    rules_changed = bool(paths(*changed, '--', TOOL, '.githooks/pre-commit', 'scripts/lint_staged_text.py'))
    selectors = json.loads(git('show', f':{TOOL}/targets.json'))
    # Apply UI exclusions only to the UI selection, as in the full check.
    selected = set()
    for group in selectors.values():
        args = ['ls-files', '--cached', '-z'] if rules_changed else [*changed, '--diff-filter=ACMT']
        selected.update(paths(*args, '--', *group))
    if not selected and not rules_changed:
        return 0

    modules = dependencies()
    selected.update(paths('ls-files', '--cached', '-z', '--', TOOL))
    names = b''.join(os.fsencode(name) + b'\0' for name in sorted(selected))
    with tempfile.TemporaryDirectory(prefix='ridecom-textlint-') as temporary:
        snapshot = Path(temporary).resolve()
        git('checkout-index', '--ignore-skip-worktree-bits', f'--prefix={snapshot}/', '-z', '--stdin', data=names)
        if any((snapshot / name).is_symlink() for name in selected):
            raise RuntimeError('文書または検査ツールのシンボリックリンクを確認してください。')
        # The normal linter discovers tracked files. Keep the temporary repository
        # independent even when Git supplies a temporary index for a partial commit.
        env = os.environ.copy()
        for name in git('rev-parse', '--local-env-vars').decode().splitlines():
            env.pop(name, None)
        def run(args: list[str]) -> None:
            subprocess.run(args, cwd=snapshot, env=env, check=True, stderr=subprocess.PIPE)
        run(['git', 'init', '--quiet', '--template='])
        run(['git', 'add', '--force', '--intent-to-add', '--', '.'])
        (snapshot / TOOL / 'node_modules').symlink_to(modules, target_is_directory=True)
        return subprocess.run(['node', f'{TOOL}/lint.mjs'], cwd=snapshot, env=env, check=False).returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except RuntimeError as error:
        sys.exit(str(error))
    except (KeyError, ValueError, OSError, subprocess.SubprocessError):
        sys.exit('コミットする文章を検査できません。Git、Node.js、文書検査ツールの準備を確認してください。')
