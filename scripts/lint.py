#!/usr/bin/env python3
"""Run read-only language checks across the repository or on files changed since a commit."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WEB = {".js", ".cjs", ".mjs", ".ts", ".tsx", ".mts", ".cts"}


def git_paths(*args: str) -> set[Path]:
    data = subprocess.check_output(["git", *args], cwd=ROOT)
    return {Path(os.fsdecode(item)) for item in data.split(b"\0") if item}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="check whole changed files, including untracked source")
    parser.add_argument("--web", action="store_true", help="only JavaScript and TypeScript")
    args = parser.parse_args()
    untracked = git_paths("ls-files", "--others", "--exclude-standard", "-z")
    if args.base:
        revision = subprocess.check_output(
            ["git", "rev-parse", "--verify", "--end-of-options", args.base + "^{commit}"], cwd=ROOT, text=True
        ).strip()
        paths = git_paths("diff", "--name-only", "--diff-filter=ACMRT", "-z", revision, "--")
    else:
        paths = git_paths("ls-files", "-z")
    paths |= untracked
    # A rule or compiler change can invalidate files whose text has not changed.
    config_inputs = {Path(p) for p in ("biome.json", "server/tsconfig.json", "server/lint-types.mjs",
                                       "server/package.json", "server/package-lock.json")}
    if args.base and (paths & config_inputs or paths & {Path("scripts/lint.py"), Path(".swiftlint.yml")}):
        all_paths = git_paths("ls-files", "-z")
        if Path("scripts/lint.py") in paths:
            paths |= all_paths
        if paths & config_inputs:
            paths |= {p for p in all_paths if p.suffix in WEB}
        if Path(".swiftlint.yml") in paths:
            paths |= {p for p in all_paths if p.suffix == ".swift"}
    selected = sorted(p for p in paths if (ROOT / p).is_file() and not (ROOT / p).is_symlink())
    ok = True

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
        with subprocess.Popen(
            [binary, *command[1:], *(files or [])], cwd=ROOT, env={**os.environ, "PATH": search_path},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
        ) as process:
            if process.stdout is None:
                raise RuntimeError("lint output unavailable")
            for line in process.stdout:
                sys.stdout.write(line.replace(str(ROOT) + os.sep, "").replace(str(Path.home()) + os.sep, "~/"))
            ok = process.wait() == 0 and ok

    web = [str(p) for p in selected if p.suffix in WEB]
    run(["biome", "lint", "--error-on-warnings", "--reporter=concise", "--max-diagnostics=none"], web)
    worker = [s for s in web if s.startswith("server/src/") and Path(s).suffix in {".ts", ".tsx", ".mts", ".cts"}]
    if worker:
        run(["node", "server/lint-types.mjs"], worker)
        run(["npm", "--prefix", "server", "run", "type-check"])
    if not args.web:
        swift = [str(p) for p in selected if p.suffix == ".swift"]
        run(["swiftlint", "lint", "--strict", "--quiet", "--cache-path", ".validation/swiftlint-cache", "--config", ".swiftlint.yml"], swift)
        python = [str(p) for p in selected if p.suffix == ".py"]
        run(["ruff", "check", "--select", "E4,E7,E9,F,B,ANN,RUF100", "--output-format", "concise"], python)
        run(["ty", "check", "--error-on-warning", "--output-format", "concise"], python)
        run(["shellcheck", "--severity=style", "--format=gcc"], [str(p) for p in selected if p.suffix == ".sh"])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
