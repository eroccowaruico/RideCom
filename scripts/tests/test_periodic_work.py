"""Regression cases for overlapping deadlines and missing acceptance records."""
import unittest
from datetime import datetime

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
