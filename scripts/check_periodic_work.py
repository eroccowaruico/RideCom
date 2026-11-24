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

# Existing obligations through this shared snapshot retain their original identifiers.
CUTOVER = "a0a6001a593139a0cfe687a05a483cceff40cde5"
CUTOVER_BUILD = 2427
CUTOVER_COMMITS = 2528
CADENCE = {"重要度": (10, 0), "バックログ": (20, 5), "Xcode": (20, 15), "コード整理": (60, 0),
           "コードと文書": (50, 25), "Archive": (40, 30), "全体監査": (100, 0)}


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args]).decode()


def periodic_overhead(revision: str, *, explain: bool = False) -> tuple[int, int]:
    """Count marked first-parent commits and their own increases of the shared build number."""
    span = f"{CUTOVER}..{revision}"
    logs = git("log", "--first-parent", "--format=%H%x09%(trailers:key=Ride-Periodic,valueonly,separator=%x2C)", span)
    marked: dict[str, str] = {}
    for line in logs.splitlines():
        commit, _, label = line.partition("\t")
        if re.fullmatch("(?:" + "|".join(RULES) + r")@[0-9]+", label):
            marked[commit] = label
        elif label:
            print(f"{commit[:12]}: 定期作業の識別子が不正です。通常変更として数えます。", file=sys.stderr)
    if not marked:
        return 0, 0
    patches = git("log", "--first-parent", "--diff-merges=first-parent", "--format=%x00%H", "--patch",
                  "--unified=0", span, "--", PROJECT)
    increments: dict[str, int] = {}
    for patch in patches.split("\0")[1:]:
        commit, _, diff = patch.partition("\n")
        if commit not in marked:
            continue
        old, new = (set(map(int, re.findall(rf"^{prefix}\s*CURRENT_PROJECT_VERSION = (\d+);", diff, re.MULTILINE)))
                    for prefix in ("-", r"\+"))
        if old and new and max(new) > max(old):
            increments[commit] = max(new) - max(old)
    if explain:
        for commit, label in marked.items():
            print(f"除外 {commit[:12]}  {label}  ビルド +{increments.get(commit, 0)}、コミット +1")
    return sum(increments.values()), len(marked)


def next_point(current: int, interval: int, phase: int) -> int:
    return current + 1 + (phase - current - 1) % interval


def upcoming(build: int, commits: int, now: datetime, overhead: tuple[int, int]) -> list[str]:
    lines = [f"ビルド: 実番号 {build} − 定期作業 {overhead[0]} = 通常換算 {build - overhead[0]}",
             f"コミット: 実件数 {commits} − 定期作業 {overhead[1]} = 通常換算 {commits - overhead[1]}",
             "次回予定（実番号の最短見込みは、以降の定期作業によって後ろに動きます）"]
    for name, (interval, phase) in CADENCE.items():
        axis = RULES[name][0]
        raw, excluded, unit = ((build, overhead[0], "ビルド") if axis == "build" else
                               (commits, 0 if name == "全体監査" else overhead[1], "コミット"))
        current = raw - excluded
        target = next_point(current, interval, phase)
        basis = "実件数" if name == "全体監査" else "通常換算"
        lines.append(f"{name}: {basis} {target}（あと {target - current} {unit}、実番号 {target + excluded}）")
    step = RULES["資源と費用"][1]
    local = now.astimezone(JST)
    next_time = local.replace(minute=0, second=0, microsecond=0) + timedelta(hours=step - local.hour % step)
    lines.append(f"資源と費用: {next_time:%Y-%m-%d %H:%M} JST")
    return lines


def due_rows(record: str, build: int, commits: int, now: datetime,
             read_evidence: Callable[[str], str], overhead: tuple[int, int] = (0, 0)) -> list[tuple[str, str]]:
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
            limit, cut, excluded = ((build, CUTOVER_BUILD, overhead[0]) if axis == "build"
                                    else (commits, CUTOVER_COMMITS, 0 if name == "全体監査" else overhead[1]))
            interval, phase = CADENCE[name]
            first = next_point(cut, interval, phase)
            points = [str(n) for n in range(start, min(cut, limit) + 1, step)]
            points.extend(str(n) for n in range(first, limit - excluded + 1, interval))
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
    parser.add_argument("--explain", action="store_true", help="除外したコミット、対象回、ビルド増分を表示")
    args = parser.parse_args()
    shared = git("rev-parse", "origin/main").strip()
    # Use the actual commit index in the hook; at selection time use shared main.
    ref = "" if args.commit else shared
    @cache
    def read(path: str) -> str:
        return git("show", f"{ref}:{path}")
    versions = set(re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", git("show", f"{shared}:{PROJECT}")))
    if len(versions) != 1:
        raise ValueError("全構成の共通ビルド番号を確認してください")
    if args.commit and LEDGER in git("ls-tree", "--name-only", "HEAD", LEDGER).splitlines():
        def keys(data: str) -> set[tuple[str, ...]]:
            return {tuple(line.split("\t")[:2]) for line in data.splitlines()[1:]}
        if keys(git("show", f"HEAD:{LEDGER}")) - keys(read(LEDGER)):
            raise ValueError("以前の節目の行を保持してください")
    build = int(versions.pop())
    commits = int(git("rev-list", "--first-parent", "--count", shared))
    now = datetime.now(JST)
    overhead = periodic_overhead(shared, explain=args.explain)
    pending = due_rows(read(LEDGER), build, commits, now, read, overhead)
    if not args.commit:
        print(f"共有main {shared[:12]}（{now:%Y-%m-%d %H:%M} JST）")
        print(*upcoming(build, commits, now, overhead), sep="\n")
        print("到来済み・未完:" if pending else "到来済みの未完: なし")
    for key, state in pending:
        print(key, state)
    if not pending:
        return 0
    if args.commit:
        paths = git("diff", "--cached", "--no-renames", "--name-only", "-z").split("\0")[:-1]
        mode = os.environ.get("RIDE_WORK", "")
        governance = {"AGENTS.md", LEDGER, ".githooks/pre-commit", ".githooks/prepare-commit-msg", "scripts/check_periodic_work.py",
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
    print("定期作業が残っています。新規着手は停止します。着手済みの差分は開発方針の「前件の共有」で検証・コミット・pushしてから切り替えてください。")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"節目を判定できません: {error}")
