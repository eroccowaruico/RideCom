import plistlib
import tempfile
import unittest
from pathlib import Path
from uuid import UUID

from scripts import prepare_installed_call_trial as installed_trial


class InstalledCallTrialPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.source = Path(root.name) / 'generated.xctestrun'
        self.destination = Path(root.name) / 'installed.xctestrun'
        self.trial = UUID('ca422e94-e64e-43a7-86da-8d4c98b15df7')
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

    def test_selects_only_installed_artifacts_and_does_not_configure_product(self) -> None:
        self.write_source()
        original = self.source.read_bytes()
        installed_trial.prepare(self.source, self.destination, self.trial)
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

    def test_refuses_simulator_artifacts(self) -> None:
        self.target['TestHostPath'] = installed_trial.RUNNER_PATH.replace('iphoneos', 'iphonesimulator')
        self.write_source()
        with self.assertRaises(ValueError):
            installed_trial.prepare(self.source, self.destination, self.trial)
        self.assertFalse(self.destination.exists())

    def test_refuses_to_overwrite_a_plan(self) -> None:
        self.write_source()
        original = self.source.read_bytes()
        with self.assertRaises(FileExistsError):
            installed_trial.prepare(self.source, self.source, self.trial)
        self.assertEqual(self.source.read_bytes(), original)
