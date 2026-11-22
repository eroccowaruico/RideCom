#!/usr/bin/env python3
"""Run read-only language checks across the repository or on files changed since a commit."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER_TYPES = {".ts", ".tsx", ".mts", ".cts"}
WEB = {".js", ".jsx", ".cjs", ".mjs", *WORKER_TYPES}
COMMIT_HOOK = Path(".githooks/pre-commit")
CONFIG_SUFFIXES = {
    Path("biome.json"): WEB,
    Path("server/tsconfig.json"): WEB,
    Path("server/lint-types.mjs"): WEB,
    Path("server/package.json"): WEB,
    Path("server/package-lock.json"): WEB,
    Path("pyproject.toml"): {".py"},
    Path(".shellcheckrc"): {".sh"},
    Path(".swiftlint.yml"): {".swift"},
}


def git_paths(*args: str) -> set[Path]:
    data = subprocess.check_output(["git", *args], cwd=ROOT)
    return {Path(os.fsdecode(item)) for item in data.split(b"\0") if item}


def audit_paths(base: str | None) -> set[Path]:
    untracked = git_paths("ls-files", "--others", "--exclude-standard", "-z")
    if base is None:
        return git_paths("ls-files", "-z") | untracked
    revision = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", base + "^{commit}"], cwd=ROOT, text=True
    ).strip()
    # Keep deleted paths and both sides of renames for configuration and Worker invalidation.
    changed = git_paths("diff", "--no-renames", "--name-only", "-z", revision, "--") | untracked
    return expand_changes(changed)


def expand_changes(changed: set[Path]) -> set[Path]:
    if Path("scripts/lint.py") in changed:
        return git_paths("ls-files", "-z") | changed
    affected = {suffix for config in changed for suffix in CONFIG_SUFFIXES.get(config, set())}
    if affected:
        changed.update(p for p in git_paths("ls-files", "-z") if language_suffix(p) in affected)
    return changed


def language_suffix(path: Path) -> str:
    return ".sh" if path == COMMIT_HOOK else path.suffix


def lint_staged(web_only: bool) -> int:
    # Git supplies the commit index, including the temporary index for "git commit -- <path>".
    changed = git_paths("diff", "--cached", "--no-renames", "--name-only", "-z", "--")
    paths = expand_changes(changed)
    languages = WEB if web_only else WEB | {".swift", ".py", ".sh"}
    if not any(language_suffix(p) in languages for p in paths) and not changed.intersection(CONFIG_SUFFIXES):
        return 0
    with tempfile.TemporaryDirectory(prefix="ridecom-lint-") as directory:
        snapshot = Path(directory)
        subprocess.run(["git", "checkout-index", "--all", "--ignore-skip-worktree-bits",
                        "--prefix=" + str(snapshot) + os.sep], cwd=ROOT, check=True)
        if any(p.is_relative_to("server/src") and p.suffix in WORKER_TYPES for p in paths):
            installed = ROOT / "server/node_modules"
            modules = snapshot / "server/node_modules"
            if installed.is_dir() and modules.parent.is_dir() and not modules.parent.is_symlink():
                modules.symlink_to(installed, target_is_directory=True)
        return run_checks(snapshot, paths, web_only)


def run_checks(root: Path, paths: set[Path], web_only: bool) -> int:
    selected = sorted(p for p in paths if (root / p).is_file() and not (root / p).is_symlink())
    suffixes = {language_suffix(p) for p in paths}
    if web_only:
        suffixes &= WEB
    ok = True
    # A missing native configuration would otherwise silently restore weaker defaults.
    for config in ("biome.json", ".swiftlint.yml", "pyproject.toml", ".shellcheckrc"):
        path = Path(config)
        if suffixes & CONFIG_SUFFIXES[path] and not (root / path).is_file():
            print(f"{config}: required lint configuration unavailable", file=sys.stderr)
            ok = False

    def run(command: list[str], files: list[str] | None = None) -> None:
        nonlocal ok
        if files == []:
            return
        tool = command[0]
        # Finder-launched Xcode does not inherit the interactive Homebrew PATH.
        search_path = os.pathsep.join([os.environ.get("PATH", os.defpath), "/opt/homebrew/bin", "/usr/local/bin"])
        binary = shutil.which(tool, path=search_path)
        if not binary:
            print(f"{tool}: required tool unavailable", file=sys.stderr)
            ok = False
            return
        print(f"{tool}: {len(files)} file(s)" if files else "Worker type-check", flush=True)
        environment = {**os.environ, "PATH": search_path}
        if tool == "swiftlint":
            # Match the Xcode validation launcher when invoked directly from Finder or a shell.
            environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
        with subprocess.Popen(
            [binary, *command[1:], *(files or [])], cwd=root, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
        ) as process:
            if process.stdout is None:
                raise RuntimeError("lint output unavailable")
            for line in process.stdout:
                sys.stdout.write(line.replace(str(root) + os.sep, "").replace(str(Path.home()) + os.sep, "~/"))
            ok = process.wait() == 0 and ok

    web = [str(p) for p in selected if p.suffix in WEB]
    run(["biome", "lint", "--error-on-warnings", "--reporter=concise", "--max-diagnostics=none"], web)
    worker_paths = {p for p in paths if p.is_relative_to("server/src") and p.suffix in WORKER_TYPES}
    if worker_paths:
        run(["node", "server/lint-types.mjs"], [str(p) for p in selected if p in worker_paths])
        run(["npm", "--prefix", "server", "run", "type-check"])
    if not web_only:
        swift = [str(p) for p in selected if p.suffix == ".swift"]
        run(["swiftlint", "lint", "--strict", "--quiet", "--cache-path", ".validation/swiftlint-cache", "--config", ".swiftlint.yml"], swift)
        python = [str(p) for p in selected if p.suffix == ".py"]
        run(["ruff", "check", "--output-format", "concise"], python)
        run(["ty", "check", "--output-format", "concise"], python)
        run(["shellcheck", "--format=gcc"], [str(p) for p in selected if language_suffix(p) == ".sh"])
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--base", help="check whole changed files, including untracked source")
    selection.add_argument("--staged", action="store_true", help="check the exact contents selected for commit")
    parser.add_argument("--web", action="store_true", help="only JavaScript and TypeScript")
    args = parser.parse_args()
    if args.staged:
        return lint_staged(args.web)
    return run_checks(ROOT, audit_paths(args.base), args.web)


if __name__ == "__main__":
    sys.exit(main())
