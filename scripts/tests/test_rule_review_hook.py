"""Exercise the rule-review hook through normal Git commits in an empty repository."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class RuleReviewHookTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git("init", "-q")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test")
        self.git("config", "commit.gpgsign", "false")
        hooks = self.repo / ".git/hooks"
        self.git("config", "core.hooksPath", str(hooks))
        shutil.copy2(Path(__file__).resolve().parents[2] / ".githooks/commit-msg", hooks)

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", *args], cwd=self.repo, check=check, capture_output=True, text=True)

    def stage(self, name: str) -> None:
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("fixture\n")
        self.git("add", "--", name)

    def commit(self, trailers: str = "", *, accepted: bool) -> None:
        result = self.git("commit", "-qm", "fixture\n\n" + trailers, check=False)
        self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_unstaged_policy_does_not_block_product_commit(self) -> None:
        (self.repo / "AGENTS.md").write_text("unstaged")
        self.stage("app.swift")
        self.commit(accepted=True)

    def test_move_out_of_skills_still_requires_review(self) -> None:
        self.stage(".agents/skills/example/SKILL.md")
        self.commit(accepted=False)
        record = "Rule-Before: 未確認なら保留\nRule-After: 同じ例で保留\nRule-Decision: 維持"
        self.commit(record, accepted=True)
        self.git("mv", ".agents/skills/example/SKILL.md", "example.md")
        self.commit(accepted=False)
        self.commit(record, accepted=True)

    def test_unresolved_or_incomplete_decision_blocks_commit(self) -> None:
        self.stage("AGENTS.md")
        examples = "Rule-Before: 保留\nRule-After: 対象限定で許可\n"
        for trailers in ("Rule-Decision: 維持", examples + "Rule-Decision: 保留",
                         examples + "Rule-Decision: 確認済み",
                         examples + "Rule-Decision: 維持\nRule-Decision: 確認済み"):
            with self.subTest(trailers=trailers):
                self.commit(trailers, accepted=False)
        self.commit(examples + "Rule-Decision: 確認済み\nRule-Consent: 試験用データだけ利用可能", accepted=True)
