import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from uuid import UUID

from scripts import prepare_installed_call_trial as installed_trial


class InstalledCallTrialPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.source = Path(root.name) / 'generated.xctestrun'
        self.destination = Path(root.name) / 'installed.xctestrun'
        self.trial = UUID('ca422e94-e64e-43a7-86da-8d4c98b15df7')
        self.runner = Path(root.name) / 'Debug-Validation-iphoneos' / 'RideIntercomUITests-Runner.app'
        self.test_bundle = self.runner / 'PlugIns' / 'RideIntercomUITests.xctest'
        self.target = {
            'BlueprintName': 'RideIntercomUITests',
            'IsUITestBundle': True,
            'TestHostBundleIdentifier': installed_trial.RUNNER_ID,
            'TestHostPath': installed_trial.RUNNER_PATH,
            'TestBundlePath': installed_trial.TEST_BUNDLE,
            'UITargetAppPath': installed_trial.APP_PATH,
            'DependentProductPaths': [installed_trial.RUNNER_PATH, installed_trial.APP_PATH],
            'UITargetAppEnvironmentVariables': {'EXAMPLE': '1'},
            'UITargetAppCommandLineArguments': ['--example'],
            'SkipTestIdentifiers': ['OtherTests'],
        }

    def write_source(self) -> None:
        self.source.write_bytes(plistlib.dumps({'TestConfigurations': [
            {'IsEnabled': True, 'TestTargets': [{'BlueprintName': 'RideIntercomTests'}, self.target]},
        ]}))

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_selects_only_installed_artifacts_and_does_not_configure_product(self, run: Mock) -> None:
        self.test_bundle.mkdir(parents=True)
        self.write_source()
        original = self.source.read_bytes()
        installed_trial.prepare(self.source, self.destination, self.trial)
        run.assert_called_once()
        self.assertIn(str(self.runner), run.call_args.args[0])
        self.assertTrue(run.call_args.kwargs['capture_output'])
        result = plistlib.loads(self.destination.read_bytes())
        target, = result['TestConfigurations'][0]['TestTargets']
        self.assertIs(target['UseDestinationArtifacts'], True)
        self.assertEqual(target['UITargetAppBundleIdentifier'], installed_trial.APP_ID)
        self.assertEqual(target['TestHostBundleIdentifier'], installed_trial.RUNNER_ID)
        self.assertEqual(target['TestBundleDestinationRelativePath'], installed_trial.TEST_BUNDLE)
        self.assertEqual(target['OnlyTestIdentifiers'], [installed_trial.SELECTOR])
        self.assertEqual(target['EnvironmentVariables'], {'RIDEINTERCOM_INSTALLED_TRIAL_ID': str(self.trial)})
        self.assertEqual(target['SystemAttachmentLifetime'], 'keepNever')
        for key in ('TestHostPath', 'TestBundlePath', 'UITargetAppPath', 'DependentProductPaths',
                    'UITargetAppEnvironmentVariables', 'UITargetAppCommandLineArguments', 'SkipTestIdentifiers'):
            self.assertNotIn(key, target)
        self.assertEqual(self.source.read_bytes(), original)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_refuses_plan_when_the_runner_or_test_bundle_is_missing(self, run: Mock) -> None:
        self.write_source()
        for runner_exists in (False, True):
            with self.subTest(runner_exists=runner_exists):
                if runner_exists:
                    self.runner.mkdir(parents=True)
                with self.assertRaises(ValueError):
                    installed_trial.prepare(self.source, self.destination, self.trial)
                self.assertFalse(self.destination.exists())
        run.assert_not_called()

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_refuses_plan_when_the_runner_signature_cannot_be_verified(self, run: Mock) -> None:
        self.test_bundle.mkdir(parents=True)
        self.write_source()
        run.side_effect = subprocess.CalledProcessError(1, 'synthetic', stderr='synthetic-private-path')
        with self.assertRaisesRegex(ValueError, '^Cannot verify the iPhoneOS test runner signature$'):
            installed_trial.prepare(self.source, self.destination, self.trial)
        self.assertFalse(self.destination.exists())

    def test_refuses_simulator_artifacts(self) -> None:
        self.target['TestHostPath'] = installed_trial.RUNNER_PATH.replace('iphoneos', 'iphonesimulator')
        self.write_source()
        with self.assertRaises(ValueError):
            installed_trial.prepare(self.source, self.destination, self.trial)
        self.assertFalse(self.destination.exists())

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_refuses_to_overwrite_a_plan(self, _run: Mock) -> None:
        self.test_bundle.mkdir(parents=True)
        self.write_source()
        original = self.source.read_bytes()
        with self.assertRaises(FileExistsError):
            installed_trial.prepare(self.source, self.source, self.trial)
        self.assertEqual(self.source.read_bytes(), original)


class InstalledCallTrialDeviceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.apps = [
            {'bundleIdentifier': installed_trial.APP_ID, 'bundleVersion': '2440'},
            {'bundleIdentifier': installed_trial.RUNNER_ID, 'bundleVersion': 'not-reported'},
        ]
        self.device = 'synthetic-destination'

    def response(self, result: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess([], 0, json.dumps({'result': result}), 'synthetic-personal-data')

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_reports_installed_artifacts_and_locked_state(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps}), self.response({'passcodeRequired': True}),
            self.response({'runningProcesses': [{'executable': 'synthetic-private-path'}]}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report, {
            'app': 'installed', 'app_build': '2440', 'runner': 'installed', 'lock': 'locked', 'process': 'running',
            'next_step': 'try_running_app',
        })
        self.assertEqual(status, 0)
        self.assertEqual(run.call_count, 3)
        self.assertIn('RideIntercom.app/RideIntercom', run.call_args_list[2].args[0])
        for call, command in zip(run.call_args_list, ('apps', 'lockState', 'processes')):
            self.assertEqual(call.args[0][:5], ['xcrun', 'devicectl', 'device', 'info', command])
            self.assertIn(self.device, call.args[0])
            self.assertTrue(call.kwargs['capture_output'])

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_missing_runner_is_visible_while_app_is_installed(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps[:1]}), self.response({'passcodeRequired': True}),
            self.response({'runningProcesses': []}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report, {
            'app': 'installed', 'app_build': '2440', 'runner': 'missing', 'lock': 'locked', 'process': 'absent',
            'next_step': 'unlock_for_runner_and_launch',
        })
        self.assertEqual(status, 1)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_unreadable_inventory_does_not_report_missing_artifacts(self, run: Mock) -> None:
        run.side_effect = [
            subprocess.TimeoutExpired('synthetic', 1), self.response({'passcodeRequired': True}),
            self.response({'runningProcesses': []}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report, {
            'app': 'unknown', 'app_build': None, 'runner': 'unknown', 'lock': 'locked', 'process': 'absent',
            'next_step': 'unknown',
        })
        self.assertEqual(status, 2)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_unreadable_process_state_does_not_claim_app_is_inactive(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps}), self.response({'passcodeRequired': True}),
            subprocess.TimeoutExpired('synthetic', 1),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report['process'], 'unknown')
        self.assertEqual(report['next_step'], 'unknown')
        self.assertEqual(status, 2)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_installed_app_without_process_needs_unlock_even_with_runner(self, run: Mock) -> None:
        for locked, next_step in [(True, 'unlock_for_launch'), (False, 'try_launch')]:
            with self.subTest(locked=locked):
                run.side_effect = [
                    self.response({'apps': self.apps}), self.response({'passcodeRequired': locked}),
                    self.response({'runningProcesses': []}),
                ]
                report, status = installed_trial.check_device(self.device)
                self.assertEqual(report['next_step'], next_step)
                self.assertEqual(status, 0)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_running_app_can_be_tried_without_installing_a_runner_while_locked(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps[:1]}), self.response({'passcodeRequired': True}),
            self.response({'runningProcesses': [{}]}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report['next_step'], 'try_running_app')
        self.assertEqual(status, 1)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_missing_testflight_app_is_not_treated_as_launchable(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps[1:]}), self.response({'passcodeRequired': False}),
            self.response({'runningProcesses': []}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report['next_step'], 'app_missing')
        self.assertEqual(status, 1)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_missing_runner_can_be_prepared_when_unlocked(self, run: Mock) -> None:
        run.side_effect = [
            self.response({'apps': self.apps[:1]}), self.response({'passcodeRequired': False}),
            self.response({'runningProcesses': []}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report['next_step'], 'install_runner_and_launch')
        self.assertEqual(status, 1)

    @patch('scripts.prepare_installed_call_trial.subprocess.run')
    def test_device_text_cannot_enter_the_report(self, run: Mock) -> None:
        self.apps[0]['bundleVersion'] = 'synthetic-personal-data'
        run.side_effect = [
            self.response({'apps': self.apps}), self.response({'passcodeRequired': 'synthetic-private'}),
            self.response({'runningProcesses': 'synthetic-private-process-data'}),
        ]
        report, status = installed_trial.check_device(self.device)
        self.assertEqual(report, {
            'app': 'installed', 'app_build': None, 'runner': 'installed', 'lock': 'unknown', 'process': 'unknown',
            'next_step': 'unknown',
        })
        self.assertEqual(status, 2)
