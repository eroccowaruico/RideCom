"""Exercise the audit through a real index using synthetic inputs only."""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import unittest

CHECK = Path(__file__).resolve().parents[2] / '.agents/skills/security-audit/scripts/check_staged.py'


TEST_ENV = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1'}
EMAIL = 'synthetic' + '@' + 'example.invalid'


class StagedAuditTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.git('init', '-q')

    def git(self, *args):
        subprocess.run(['/usr/bin/git', *args], cwd=self.root, env=TEST_ENV, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def stage(self, name, data):
        (self.root / name).write_bytes(data)
        self.git('add', '--', name)

    def check(self, code, **options):
        result = subprocess.run([sys.executable, '-I', '-S', str(CHECK)],
                                cwd=options.pop('cwd', self.root), capture_output=True,
                                env=options.pop('env', TEST_ENV), **options)
        self.assertEqual(result.returncode, code)
        self.assertEqual(result.stderr, b'')
        return json.loads(result.stdout)

    def test_empty_index_and_clean_staged_content(self):
        self.assertEqual(self.check(0)['state'], 'empty')
        self.stage('guide.md', b'Use the local test fixture.')
        (self.root / 'guide.md').write_bytes(b'contact: ' + EMAIL.encode())
        report = self.check(0)
        self.assertEqual(report, {'state': 'checked', 'signals': []})

    def test_only_fixed_categories_leave_the_process(self):
        pem = b'-----BEGIN ' + b'PRIVATE KEY-----'
        self.stage(EMAIL, pem + b'\n' + b'ghp_' + b'X' * 36)
        (self.root / EMAIL).write_bytes(b'already cleaned in the worktree')
        self.assertEqual(self.check(1), {'state': 'review', 'signals': [
            'credential', 'personal-data', 'private-key']})

    def test_sensitive_container_and_uninspectable_content(self):
        self.stage('.env', b'fixture')
        self.stage('binary', b'\0fixture')
        self.stage('large', b'a' * (2 * 1024 * 1024 + 1))
        (self.root / 'pointer').symlink_to('/unavailable/' + EMAIL)
        self.git('add', '--', 'pointer')
        self.assertEqual(self.check(1), {'state': 'review', 'signals': [
            'opaque', 'sensitive-file']})

    def test_failure_does_not_emit_path_or_git_diagnostics(self):
        with tempfile.TemporaryDirectory() as outside:
            self.assertEqual(self.check(2, cwd=outside), {'state': 'unavailable', 'signals': []})

    def test_nonstandard_index_is_not_certified_as_default(self):
        self.stage('guide.md', b'fixture')
        self.assertEqual(self.check(2, env=dict(TEST_ENV, GIT_INDEX_FILE='/missing/' + EMAIL)),
                         {'state': 'unavailable', 'signals': []})

    def test_renewed_snapshot_is_checked_again(self):
        self.stage('fixture', b'contact: ' + EMAIL.encode())
        self.assertEqual(self.check(1)['signals'], ['personal-data'])
        self.stage('fixture', b'public fixture')
        for _ in range(2):
            self.assertEqual(self.check(0), {'state': 'checked', 'signals': []})

    def test_ambient_git_configuration_cannot_redirect_the_scan(self):
        self.stage('guide.md', b'contact: ' + EMAIL.encode())
        env = dict(TEST_ENV, GIT_TRACE='1', GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='core.pager',
                   GIT_CONFIG_VALUE_0='cat')
        self.assertEqual(self.check(1, env=env), {'state': 'review', 'signals': ['personal-data']})


if __name__ == '__main__':
    unittest.main()
