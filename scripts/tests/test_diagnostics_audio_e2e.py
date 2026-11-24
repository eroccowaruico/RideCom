import subprocess
import tempfile
import traceback
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import diagnostics_audio_e2e


class DiagnosticsAudioTest(unittest.TestCase):
    def test_invitation_timeout_does_not_include_the_url_in_reported_error(self) -> None:
        invite = 'fixture-invitation-canary'
        with tempfile.TemporaryDirectory() as directory:
            invitation = Path(directory) / 'receiver-invitation.url'
            invitation.write_text(invite)
            failure = subprocess.TimeoutExpired(['openurl', invite], timeout=20)
            with (
                patch.object(diagnostics_audio_e2e.subprocess, 'run', side_effect=failure),
                self.assertRaisesRegex(RuntimeError, 'Could not open the synthetic invitation') as raised,
            ):
                diagnostics_audio_e2e.open_invitation('fixture-receiver', invitation)
        rendered = ''.join(traceback.format_exception(raised.exception))
        self.assertNotIn(invite, rendered)
