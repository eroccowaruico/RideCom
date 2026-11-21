#!/usr/bin/env python3
"""Run read-only language checks across the repository or on files changed since a commit."""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER_TYPES = {".ts", ".tsx", ".mts", ".cts"}
WEB = {".js", ".cjs", ".mjs", *WORKER_TYPES}
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
    if Path("scripts/lint.py") in changed:
        return git_paths("ls-files", "-z") | changed
    affected = {suffix for config in changed for suffix in CONFIG_SUFFIXES.get(config, set())}
    if affected:
        changed.update(p for p in git_paths("ls-files", "-z") if p.suffix in affected)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="check whole changed files, including untracked source")
    parser.add_argument("--web", action="store_true", help="only JavaScript and TypeScript")
    args = parser.parse_args()
    paths = audit_paths(args.base)
    selected = sorted(p for p in paths if (ROOT / p).is_file() and not (ROOT / p).is_symlink())
    suffixes = {p.suffix for p in paths}
    if args.web:
        suffixes &= WEB
    ok = True
    # A missing native configuration would otherwise silently restore weaker defaults.
    for config in ("biome.json", ".swiftlint.yml", "pyproject.toml", ".shellcheckrc"):
        path = Path(config)
        if suffixes & CONFIG_SUFFIXES[path] and not (ROOT / path).is_file():
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
            [binary, *command[1:], *(files or [])], cwd=ROOT, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
        ) as process:
            if process.stdout is None:
                raise RuntimeError("lint output unavailable")
            for line in process.stdout:
                sys.stdout.write(line.replace(str(ROOT) + os.sep, "").replace(str(Path.home()) + os.sep, "~/"))
            ok = process.wait() == 0 and ok

    web = [str(p) for p in selected if p.suffix in WEB]
    run(["biome", "lint", "--error-on-warnings", "--reporter=concise", "--max-diagnostics=none"], web)
    worker_paths = {p for p in paths if p.is_relative_to("server/src") and p.suffix in WORKER_TYPES}
    if worker_paths:
        run(["node", "server/lint-types.mjs"], [str(p) for p in selected if p in worker_paths])
        run(["npm", "--prefix", "server", "run", "type-check"])
    if not args.web:
        swift = [str(p) for p in selected if p.suffix == ".swift"]
        run(["swiftlint", "lint", "--strict", "--quiet", "--cache-path", ".validation/swiftlint-cache", "--config", ".swiftlint.yml"], swift)
        python = [str(p) for p in selected if p.suffix == ".py"]
        run(["ruff", "check", "--output-format", "concise"], python)
        run(["ty", "check", "--output-format", "concise"], python)
        run(["shellcheck", "--format=gcc"], [str(p) for p in selected if p.suffix == ".sh"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
