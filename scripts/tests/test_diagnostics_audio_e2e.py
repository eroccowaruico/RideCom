import subprocess
import tempfile
import traceback
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts import diagnostics_audio_e2e


class DiagnosticsAudioTest(unittest.TestCase):
    def test_output_matches_native_audible_pcm_during_speech_and_silence(self) -> None:
        output = {'outputCallback': True, 'usesNativeOutput': True, 'muted': True, 'recordedAt': 10.0,
                  'lastNativeAudibleOutputAt': 9.8, 'nativeOutput': {'audibleDuration': 2.0}}
        self.assertEqual(diagnostics_audio_e2e.matching_output([output], 10.1, 0, 0, True), output)
        quiet = {**output, 'recordedAt': 14.0}
        self.assertEqual(diagnostics_audio_e2e.matching_output([quiet], 14.0, 4, 0, False), quiet)
        for invalid in ({**output, 'usesNativeOutput': False},
                        {**output, 'nativeOutput': {'audibleDuration': 0}},
                        {**output, 'lastNativeAudibleOutputAt': 10.2}):
            self.assertIsNone(diagnostics_audio_e2e.matching_output([invalid], 10.1, 0, 0, True))
        self.assertIsNone(diagnostics_audio_e2e.matching_output([quiet], 14.0, 4, 3, False))

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
