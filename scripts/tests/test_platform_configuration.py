"""Cross-product permissions and distribution inputs must agree before signing."""
import copy
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts import check_platform_configuration as checker

ROOT = Path(__file__).resolve().parents[2]


class PlatformConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = checker.load_project(ROOT)

    def test_watch_scheme_has_standard_run_profile_analyze_and_archive_actions(self) -> None:
        scheme = ET.parse(ROOT / 'RideIntercom.xcodeproj/xcshareddata/xcschemes/RideIntercomWatch.xcscheme').getroot()
        for name, configuration in [('LaunchAction', 'Debug'), ('ProfileAction', 'Release'),
                                    ('AnalyzeAction', 'Debug'), ('ArchiveAction', 'Release')]:
            with self.subTest(action=name):
                action = scheme.find(name)
                if action is None:
                    self.fail(f"Missing {name} action")
                self.assertEqual(action.get('buildConfiguration'), configuration)
                if name in ('LaunchAction', 'ProfileAction'):
                    reference = action.find('BuildableProductRunnable/BuildableReference')
                    if reference is None:
                        self.fail(f"Missing {name} product reference")
                    self.assertEqual(reference.get('BlueprintIdentifier'), '0CCFFDBF2F4415059F932F5F')
                    self.assertEqual(reference.get('BuildableName'), 'RideIntercomWatch.app')

    def test_project_has_only_normal_and_shared_validation_configurations(self) -> None:
        objects = self.project['objects']
        for value in objects.values():
            if value.get('isa') == 'XCConfigurationList':
                names = {objects[key]['name'] for key in value['buildConfigurations']}
                self.assertEqual(names, {'Debug', 'Release', 'Debug-Validation', 'Release-Validation'})
        self.assertFalse((ROOT / 'Configuration/StoreKitValidation.xcconfig').exists())

    def test_storekit_native_suites_use_the_shared_build_but_explicit_test_selection(self) -> None:
        import json
        plan = json.loads((ROOT / 'Configuration/StoreKit.xctestplan').read_text())
        self.assertEqual(set(plan['testTargets'][0].get('selectedTests', [])), {
            'StoreEntitlementTests', 'StoreKitAccessTests', 'StoreDistributionAccessTests', 'LocalStoreKitTests'})
        ordinary = ET.parse(ROOT / 'RideIntercom.xcodeproj/xcshareddata/xcschemes/RideIntercom.xcscheme')
        excluded = {v.attrib['Identifier'] for v in ordinary.findall('TestAction/Testables/TestableReference/SkippedTests/Test')}
        self.assertEqual(excluded, {'LocalStoreKitTests', 'StorePurchaseUITests'})
        ui = ET.parse(ROOT / 'RideIntercom.xcodeproj/xcshareddata/xcschemes/RideIntercom-StoreKitUITests.xcscheme')
        self.assertEqual([v.attrib['Identifier'] for v in ui.findall('TestAction/Testables/TestableReference/SelectedTests/Test')], ['StorePurchaseUITests'])
        for name in ['RideIntercom-StoreKitTests', 'RideIntercom-StoreKitUITests']:
            scheme = ET.parse(ROOT / ('RideIntercom.xcodeproj/xcshareddata/xcschemes/' + name + '.xcscheme'))
            action = scheme.find('TestAction')
            if action is None:
                self.fail(f'Missing TestAction in {name}')
            self.assertEqual(action.get('buildConfiguration'), 'Debug-Validation')

    def test_catalog_fixture_requires_validation_compilation_and_explicit_environment(self) -> None:
        source = (ROOT / 'RideIntercom/StoreKit/StoreProductCatalog.swift').read_text()
        self.assertIn('#if DEBUG && RIDEINTERCOM_VALIDATION', source)
        self.assertIn('environment["RIDEINTERCOM_LOCAL_TESTING"] == "1"', source)
        self.assertIn('environment["RIDEINTERCOM_STOREKIT_CATALOG_FIXTURE"]', source)
        for config in self.project['objects'].values():
            if config.get('isa') == 'XCBuildConfiguration' and config['name'] in {'Debug', 'Release'}:
                flags = config.get('buildSettings', {}).get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '')
                self.assertNotIn('RIDEINTERCOM_VALIDATION', flags)

    def test_repository_has_complete_minimum_platform_inputs(self) -> None:
        self.assertEqual(checker.check(ROOT), [])

    def test_watch_distribution_exclusions_accept_xcode_list_and_string_settings(self) -> None:
        settings = {
            'EXCLUDED_SOURCE_FILE_NAMES': 'RideIntercomWatch.app',
            'EXCLUDED_EXPLICIT_TARGET_DEPENDENCIES': 'RideIntercomWatch',
        }
        for uses_list in (False, True):
            with self.subTest(uses_list=uses_list):
                project = copy.deepcopy(self.project)
                config = next(cfg['buildSettings'] for cfg in checker.target_configurations(project, 'RideIntercom')
                              if cfg['name'] == 'Release')
                for name, product in settings.items():
                    inputs = ['$(inherited)', product]
                    config[name] = inputs if uses_list else ' '.join(inputs)
                self.assertEqual(checker.check(ROOT, project), [])
                config['EXCLUDED_SOURCE_FILE_NAMES'] = ['$(inherited)'] if uses_list else '$(inherited)'
                self.assertIn('Exclude the Watch product only from the distribution Release configuration.',
                              checker.check(ROOT, project))

    def test_icon_composer_resource_is_registered_for_app_and_watch(self) -> None:
        app_icon = ROOT / 'RideIntercom/RideComAppIcon.icon'
        self.assertTrue((app_icon / 'icon.json').is_file())
        self.assertFalse((ROOT / 'RideIntercomWatch/RideComAppIcon.icon').exists())
        watch_resource_paths = checker.target_resource_paths(self.project, 'RideIntercomWatch')
        self.assertIn('RideIntercom/RideComAppIcon.icon', watch_resource_paths)
        for target in ('RideIntercom', 'RideIntercomWatch'):
            for settings in checker.target_settings(self.project, target):
                with self.subTest(target=target):
                    self.assertEqual(settings.get('ASSETCATALOG_COMPILER_APPICON_NAME'), 'RideComAppIcon')

    def test_all_xcode_deployment_targets_use_version_27(self) -> None:
        deployment_settings = {
            'IPHONEOS_DEPLOYMENT_TARGET',
            'MACOSX_DEPLOYMENT_TARGET',
            'WATCHOS_DEPLOYMENT_TARGET',
            'XROS_DEPLOYMENT_TARGET',
        }
        for config in self.project['objects'].values():
            if config.get('isa') != 'XCBuildConfiguration':
                continue
            settings = config.get('buildSettings', {})
            for setting in deployment_settings & settings.keys():
                with self.subTest(configuration=config['name'], setting=setting):
                    self.assertEqual(settings[setting], '27.0')

    def test_platform_checker_rejects_an_old_xcode_deployment_target(self) -> None:
        project = copy.deepcopy(self.project)
        config = next(
            value for value in project['objects'].values()
            if value.get('isa') == 'XCBuildConfiguration'
            and 'IPHONEOS_DEPLOYMENT_TARGET' in value.get('buildSettings', {})
        )
        config['buildSettings']['IPHONEOS_DEPLOYMENT_TARGET'] = '26.4'
        self.assertTrue(any('IPHONEOS_DEPLOYMENT_TARGET must be 27.0' in error
                            for error in checker.check(ROOT, project)))

    def test_named_validation_configurations_allow_mac_fixture_settings(self) -> None:
        for name in ('Debug-Validation', 'Release-Validation'):
            with self.subTest(configuration=name):
                project = copy.deepcopy(self.project)
                objects = project['objects']
                target = next(o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'RideIntercom')
                keys = objects[target['buildConfigurationList']]['buildConfigurations']
                config = copy.deepcopy(objects[keys[0]])
                config['name'] = name
                config['buildSettings']['ENABLE_APP_SANDBOX'] = '$(RIDEINTERCOM_VALIDATION_SANDBOX)'
                config['buildSettings']['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = '$(RIDEINTERCOM_VALIDATION_ENTITLEMENTS)'
                objects['TEST_VALIDATION_CONFIG'] = config
                keys.append('TEST_VALIDATION_CONFIG')
                self.assertEqual(checker.check(ROOT, project), [])
                config['buildSettings']['ENABLE_APP_SANDBOX'] = 'NO'
                self.assertTrue(any('sandbox network' in e for e in checker.check(ROOT, project)))

    def test_shipping_configurations_cannot_borrow_validation_exceptions(self) -> None:
        project = copy.deepcopy(self.project)
        for settings in checker.target_settings(project, 'RideIntercom'):
            settings['ENABLE_APP_SANDBOX'] = '$(RIDEINTERCOM_VALIDATION_SANDBOX)'
            settings['CODE_SIGN_ENTITLEMENTS[sdk=macosx*]'] = '$(RIDEINTERCOM_VALIDATION_ENTITLEMENTS)'
        errors = checker.check(ROOT, project)
        self.assertTrue(any('macOS entitlement' in e for e in errors))
        self.assertTrue(any('sandbox network' in e for e in errors))

    def test_watch_icon_omission_is_rejected(self) -> None:
        project = copy.deepcopy(self.project)
        for settings in checker.target_settings(project, 'RideIntercomWatch'):
            settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
        self.assertTrue(any('RideComAppIcon resource' in e for e in checker.check(ROOT, project)))

    def test_apns_configuration_cannot_drift_from_info_and_entitlement_contract(self) -> None:
        project = copy.deepcopy(self.project)
        for settings in checker.target_settings(project, 'RideIntercom'):
            settings['RIDEINTERCOM_APNS_ENVIRONMENT'] = 'sandbox'
        self.assertTrue(any('APNs environment' in e for e in checker.check(ROOT, project)))

    def test_mac_cannot_use_ios_apns_entitlement(self) -> None:
        project = copy.deepcopy(self.project)
        for settings in checker.target_settings(project, 'RideIntercom'):
            settings.pop('CODE_SIGN_ENTITLEMENTS[sdk=macosx*]', None)
        self.assertTrue(any('macOS entitlement' in e for e in checker.check(ROOT, project)))

    def test_audio_and_local_network_need_both_sandbox_directions(self) -> None:
        project = copy.deepcopy(self.project)
        for settings in checker.target_settings(project, 'RideIntercom'):
            settings['ENABLE_INCOMING_NETWORK_CONNECTIONS'] = 'NO'
        self.assertTrue(any('sandbox network' in e for e in checker.check(ROOT, project)))

    def test_embed_product_cannot_be_removed(self) -> None:
        project = copy.deepcopy(self.project)
        objects = project['objects']
        widget_refs = {key for key, obj in objects.items()
                       if obj.get('isa') == 'PBXFileReference' and obj.get('path') == 'RideIntercomWidgets.appex'}
        self.assertEqual(len(widget_refs), 1)
        widget_build_files = {key for key, obj in objects.items()
                              if obj.get('isa') == 'PBXBuildFile' and obj.get('fileRef') in widget_refs}
        app = next(obj for obj in objects.values()
                   if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'RideIntercom')
        removed = 0
        for phase_id in app['buildPhases']:
            phase = objects[phase_id]
            if phase.get('isa') == 'PBXCopyFilesBuildPhase':
                original = phase.get('files', [])
                phase['files'] = [key for key in original if key not in widget_build_files]
                removed += len(original) - len(phase['files'])
        self.assertEqual(removed, 1, 'The fixture must remove exactly one Widget embed entry.')
        self.assertTrue(any('embed Widget' in e for e in checker.check(ROOT, project)))


if __name__ == '__main__':
    unittest.main()
