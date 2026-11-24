"""List due RideCom milestones and guard a return to ordinary product work."""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from functools import cache
from pathlib import Path

JST = timezone(timedelta(hours=9))
LEDGER = "docs/development/history/定期作業の受入.tsv"
PROJECT = "RideIntercom.xcodeproj/project.pbxproj"
# Intervals match the acceptance table in the development policy.
RULES = {"重要度": ("build", 10), "バックログ": ("build", 20), "Xcode": ("build", 20),
         "コード整理": ("build", 30), "コードと文書": ("commit", 20),
         "Archive": ("commit", 30), "全体監査": ("commit", 100), "資源と費用": ("time", 6)}


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args]).decode()


def due_rows(record: str, build: int, commits: int, now: datetime,
             read_evidence: Callable[[str], str]) -> list[tuple[str, str]]:
    """The first recorded boundary per activity is the reviewed migration baseline."""
    rows: dict[str, dict[str, str]] = {name: {} for name in RULES}
    for line in record.splitlines()[1:]:
        name, point, state, source, heading = line.split("\t")
        if name not in rows or point in rows[name] or state not in {"完了", "指定延期", "未完", "進行中"}:
            raise ValueError("定期作業の重複、種別、状態を確認してください")
        if state == "指定延期" and name != "Xcode":
            raise ValueError("画面確認の延期指定を確認してください")
        if not source.startswith("docs/") or ".." in Path(source).parts or not heading:
            raise ValueError("受入の根拠を指定してください")
        if not any(s.lstrip("# ") == heading for s in read_evidence(source).splitlines() if s.startswith("#")):
            raise ValueError(f"{name} {point}: 参照先の見出しを確認してください")
        rows[name][point] = state
    pending = []
    for name, (axis, step) in RULES.items():
        if not rows[name]:
            raise ValueError(f"{name}: 初回の記録が必要です")
        if axis == "time":
            start = datetime.strptime(min(rows[name]), "%Y%m%d%H").replace(tzinfo=JST)
            if start.hour % step:
                raise ValueError("日本時間の6時間の節目を指定してください")
            count = int((now - start) // timedelta(hours=step)) + 1
            points = [(start + timedelta(hours=i * step)).strftime("%Y%m%d%H") for i in range(count)]
        else:
            start = min(map(int, rows[name]))
            if start % step:
                raise ValueError(f"{name}: 倍数の節目を指定してください")
            points = list(map(str, range(start, (build if axis == "build" else commits) + 1, step)))
        if rows[name].keys() - set(points):
            raise ValueError(f"{name}: 範囲外の節目です")
        for point in points:
            state = rows[name].get(point, "記録なし")
            if state not in {"完了", "指定延期"}:
                pending.append((f"{name}@{point}", state))
    if sum(state == "進行中" for _, state in pending) > 1:
        raise ValueError("進行中の定期作業は1件にしてください")
    return pending


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", action="store_true")
    args = parser.parse_args()
    # Use the actual commit index in the hook; at selection time use shared main.
    ref = "" if args.commit else "origin/main"
    @cache
    def read(path: str) -> str:
        return git("show", f"{ref}:{path}")
    versions = set(re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", git("show", f"origin/main:{PROJECT}")))
    if len(versions) != 1:
        raise ValueError("全構成の共通ビルド番号を確認してください")
    if args.commit and LEDGER in git("ls-tree", "--name-only", "HEAD", LEDGER).splitlines():
        def keys(data: str) -> set[tuple[str, ...]]:
            return {tuple(line.split("\t")[:2]) for line in data.splitlines()[1:]}
        if keys(git("show", f"HEAD:{LEDGER}")) - keys(read(LEDGER)):
            raise ValueError("以前の節目の行を保持してください")
    pending = due_rows(read(LEDGER), int(versions.pop()), int(git("rev-list", "--first-parent", "--count",
                                                                  "origin/main")), datetime.now(JST), read)
    for key, state in pending:
        print(key, state)
    if not pending:
        return 0
    if args.commit:
        paths = git("diff", "--cached", "--no-renames", "--name-only", "-z").split("\0")[:-1]
        mode = os.environ.get("RIDE_WORK", "")
        governance = {"AGENTS.md", LEDGER, ".githooks/pre-commit", "scripts/check_periodic_work.py",
                      "scripts/tests/test_periodic_work.py", "scripts/tests/test_language_lint.py"}
        if mode == "文書" and paths and all(p.startswith(("docs/policies/", "docs/backlog/", ".agents/skills/"))
                                           or p in governance for p in paths):
            return 0
        if mode in {key for key, state in pending if state == "進行中"}:
            return 0
        # Closing a round may remove it from the staged ledger. Match its prior active entry.
        if LEDGER in paths and mode:
            previous = git("show", f"HEAD:{LEDGER}").splitlines()[1:]
            if any(f"{r[0]}@{r[1]}" == mode and r[2] == "進行中" for r in (s.split("\t") for s in previous)):
                return 0
        if mode == "前件の共有" and os.environ.get("RIDE_WORK_RECORD") and any(
                p.startswith("docs/development/history/") for p in paths):
            note = os.environ["RIDE_WORK_RECORD"]
            if any(line.startswith("+#") and line.lstrip("+# ") == note for line in
                   git("diff", "--cached", "--unified=0", "--", "docs/development/history/").splitlines()):
                return 0
    print("定期作業が残っています。開発方針「節目の目的と成果の確認」に従ってください。")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"節目を判定できません: {error}")
