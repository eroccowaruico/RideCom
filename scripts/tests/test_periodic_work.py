"""Regression cases for overlapping deadlines and missing acceptance records."""
import os
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from scripts import check_periodic_work as gate
from scripts.check_periodic_work import JST, due_rows


class PeriodicWorkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.record = "header\n" + "".join(
            f"{kind}\t{point}\t完了\tdocs/report.md\t確認\n" for kind, point in (
                ("重要度", 60), ("バックログ", 60), ("Xcode", 60), ("コード整理", 60),
                ("コードと文書", 60), ("Archive", 60), ("全体監査", 100), ("資源と費用", 2026112418)))
        self.now = datetime(2026, 11, 24, 18, tzinfo=JST)

    def check(self, build: int, commits: int) -> dict[str, str]:
        return dict(due_rows(self.record, build, commits, self.now, lambda _: "## 確認"))

    def test_each_overlapping_requirement_remains_visible(self) -> None:
        self.assertEqual(self.check(60, 100).keys(), {"コードと文書@80", "コードと文書@100", "Archive@90"})
        self.record += "コードと文書\t100\t完了\tdocs/report.md\t確認\n"
        self.assertIn("コードと文書@80", self.check(61, 101))
        self.assertIn("Xcode@80", self.check(82, 101))
        self.assertIn("バックログ@80", self.check(82, 101))

    def test_time_advances_on_a_quiet_trunk(self) -> None:
        self.now = datetime(2026, 11, 25, 0, tzinfo=JST)
        self.assertIn("資源と費用@2026112500", self.check(60, 100))

    def test_missing_evidence_and_parallel_activity_fail(self) -> None:
        self.record = self.record.replace("完了", "進行中", 2)
        with self.assertRaises(ValueError):
            self.check(60, 100)
        self.record = self.record.replace("確認", "なし", 1)
        with self.assertRaises(ValueError):
            self.check(60, 100)

    def test_long_periodic_work_preserves_old_queue_without_generating_another_round(self) -> None:
        before = self.check(gate.CUTOVER_BUILD, gate.CUTOVER_COMMITS)
        after = dict(due_rows(self.record, gate.CUTOVER_BUILD + 90, gate.CUTOVER_COMMITS + 105,
                              self.now, lambda _: "## 確認", (90, 105)))
        self.assertEqual(after.keys() - before.keys(), {"全体監査@2600"})
        self.assertFalse(before.keys() - after.keys())
        ordinary = dict(due_rows(self.record, 2445, 2575, self.now, lambda _: "## 確認"))
        self.assertTrue({"バックログ@2445", "Xcode@2435", "Archive@2550", "コードと文書@2575"} <= ordinary.keys())
        self.assertNotIn("コード整理@2430", ordinary)

    def test_forecast_on_boundary_uses_same_next_round_as_gate(self) -> None:
        now = self.now.replace(hour=23, minute=59)
        lines = gate.upcoming(2440, 2560, now, (5, 10))
        self.assertIn("Xcode: 通常換算 2455（あと 20 ビルド、実番号 2460）", lines)
        self.assertIn("Archive: 通常換算 2590（あと 40 コミット、実番号 2600）", lines)
        self.assertIn("全体監査: 実件数 2600（あと 40 コミット、実番号 2600）", lines)
        self.assertIn("資源と費用: 2026-11-25 00:00 JST", lines)
        due = dict(due_rows(self.record, 2460, 2600, now, lambda _: "## 確認", (5, 10)))
        self.assertTrue({"Xcode@2455", "Archive@2590", "全体監査@2600"} <= due.keys())

    def test_archive_switches_to_ten_after_the_scheduled_round(self) -> None:
        for current, target in ((2630, 2670), (2669, 2670), (2670, 2680), (2680, 2690)):
            lines = gate.upcoming(2440, current + 12, self.now, (0, 12))
            self.assertIn(f"Archive: 通常換算 {target}（あと {target - current} コミット、実番号 {target + 12}）", lines)
        pending = due_rows(self.record, 2440, 2702, self.now, lambda _: "## 確認", (0, 12))
        self.assertEqual([key for key, _ in pending if key.startswith("Archive@") and int(key[8:]) >= 2630],
                         ["Archive@2630", "Archive@2670", "Archive@2680", "Archive@2690"])

    def test_hook_counts_only_the_periodic_commit_and_its_builds(self) -> None:
        hook = Path(__file__).resolve().parents[2] / ".githooks/prepare-commit-msg"
        with tempfile.TemporaryDirectory() as tmp:
            def git(*args: str, mode: str = "") -> str:
                return subprocess.check_output(["git", *args], cwd=tmp, text=True,
                                               env={**os.environ, "RIDE_WORK": mode}).strip()
            git("init", "-q")
            git("config", "user.name", "test")
            git("config", "user.email", "test")
            git("config", "commit.gpgsign", "false")
            hooks = Path(tmp, ".git/hooks")
            local_hook = hooks / hook.name
            local_hook.write_bytes(hook.read_bytes())
            local_hook.chmod(0o755)
            git("config", "core.hooksPath", str(hooks))
            project = Path(tmp, gate.PROJECT)
            project.parent.mkdir()
            def commit(build: int, mode: str = "") -> None:
                project.write_text(f"CURRENT_PROJECT_VERSION = {build};\n" * 4)
                git("add", "--", gate.PROJECT)
                git("commit", "-qm", "fixture", mode=mode)
            ledger = Path(tmp, gate.LEDGER)
            ledger.parent.mkdir(parents=True)
            ledger.write_text(self.record)
            git("add", "--", gate.LEDGER)
            commit(100)
            base = git("rev-parse", "HEAD")
            commit(107, "コードと文書@2520")
            commit(109, "前件の共有")
            with patch.object(gate, "git", git), patch.object(gate, "CUTOVER", base):
                self.assertEqual(gate.periodic_overhead("HEAD"), (7, 1))
            self.assertEqual(git("status", "--porcelain"), "")

            # A newly due round blocks starting other work, but a verified change already
            # in progress can close without unstaging it or moving it to another tree.
            record_path = "docs/development/history/前件.md"
            record = Path(tmp, record_path)
            record.parent.mkdir(parents=True, exist_ok=True)
            record.write_text("## 前件の受入\n")
            project.write_text("CURRENT_PROJECT_VERSION = 110;\n")
            git("add", "--", record_path, gate.PROJECT)
            pending = [("コードと文書@2520", "進行中")]
            with patch.object(gate, "git", git), patch.object(gate, "periodic_overhead", return_value=(0, 0)), \
                 patch.object(gate, "due_rows", return_value=pending), \
                 patch("sys.argv", ["gate", "--commit"]):
                git("update-ref", "refs/remotes/origin/main", git("rev-parse", "HEAD"))
                with patch.dict(os.environ, {"RIDE_WORK": ""}):
                    self.assertEqual(gate.main(), 1)
                self.assertEqual(set(git("diff", "--cached", "--name-only", "-z").strip("\0").split("\0")),
                                 {record_path, gate.PROJECT})
                with patch.dict(os.environ, {"RIDE_WORK": "前件の共有", "RIDE_WORK_RECORD": "前件の受入"}):
                    self.assertEqual(gate.main(), 0)
                git("commit", "-qm", "close the verified change", mode="前件の共有")
            self.assertEqual(git("status", "--porcelain"), "")
