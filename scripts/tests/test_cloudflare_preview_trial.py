from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import TextIO
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'preview_trial', Path(__file__).resolve().parents[1] / 'Cloudflare' / 'run-preview-media-trial.py')
assert SPEC is not None and SPEC.loader is not None
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)


class PreviewMediaTrialTests(unittest.TestCase):
    def test_macos_uses_shared_scheme_without_managing_a_simulator(self) -> None:
        def run(command: list[str], *, env: dict[str, str], stdout: TextIO,
                **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
            self.assertEqual(command[command.index('-destination') + 1], 'platform=macOS,arch=arm64')
            self.assertIn('RideIntercomAudioE2E', command)
            self.assertIn('-only-testing:' + trial.CASE, command)
            self.assertEqual(env['TEST_RUNNER_RIDEINTERCOM_TEST_TURN_RELAY'], '1')
            stdout.write('WebRTC speech frames: left 98/98, right 98/98\n')
            stdout.write('WebRTC UDP TURN selected: left true, right true\n' * 2)
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as output, \
             patch.object(trial.subprocess, 'run', side_effect=run) as command, \
             patch.object(trial.subprocess, 'check_output') as simctl:
            self.assertTrue(trial.media_test(
                Path(output), 'http://127.0.0.1/trial', True, False, macos=True))
        command.assert_called_once()
        simctl.assert_not_called()

    def test_simulator_is_deleted_when_testing_raises(self) -> None:
        with (patch.object(trial.subprocess, 'check_output', side_effect=[b'{"runtimes":[]}', 'test-device']),
              patch.object(trial, 'latest_runtime', return_value='test-runtime'),
              patch.object(trial, 'simulator_devices') as inventory,
              patch.object(trial.subprocess, 'run') as command,
              patch.object(trial.uuid, 'uuid4') as identifier):
            identifier.return_value.hex = '0123456789'
            inventory.return_value = [{
                'udid': 'test-device', 'name': 'RideIntercom Preview Media 01234567', 'state': 'Shutdown'}]
            with self.assertRaises(TimeoutError), trial.test_destination(False) as destination:
                self.assertEqual(destination, 'platform=iOS Simulator,id=test-device')
                raise TimeoutError
        command.assert_called_once_with(
            ['xcrun', 'simctl', 'delete', 'test-device'], check=True, capture_output=True, timeout=45)
