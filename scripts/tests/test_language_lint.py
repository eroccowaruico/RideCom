"""Keep configuration changes and deleted Worker sources visible to the lint runner."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import lint


class LanguageLintTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        root_patch = patch.object(lint, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        self.git("init", "-q")
        for name in ("biome.json", "pyproject.toml", "example.py", "example.sh", "server/src/contract.ts"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        self.git("add", ".")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "baseline")

    def git(self, *args: str) -> None:
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def test_deleted_config_checks_existing_and_untracked_python(self) -> None:
        (self.root / "pyproject.toml").unlink()
        (self.root / "added.py").touch()
        self.assertEqual(lint.audit_paths("HEAD"), {
            Path("pyproject.toml"), Path("example.py"), Path("added.py"),
        })

    def test_missing_native_config_fails_even_if_tools_succeed(self) -> None:
        (self.root / "pyproject.toml").unlink()
        with patch.object(sys, "argv", ["lint", "--base", "HEAD"]), \
                patch.object(shutil, "which", return_value="/usr/bin/true"):
            self.assertEqual(lint.main(), 1)

    def test_moved_worker_source_still_runs_project_type_check(self) -> None:
        self.git("mv", "server/src/contract.ts", "contract.ts")
        with patch.object(sys, "argv", ["lint", "--web", "--base", "HEAD"]), \
                patch.object(shutil, "which", return_value="/usr/bin/true") as invoked:
            self.assertEqual(lint.main(), 0)
        self.assertEqual([call.args[0] for call in invoked.call_args_list], ["biome", "npm"])
