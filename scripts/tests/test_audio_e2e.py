"""Failure and interruption coverage for the AI-independent audio E2E runner."""
from __future__ import annotations

import io
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Mapping
from contextlib import redirect_stderr
from pathlib import Path
from typing import ClassVar, TypedDict
from unittest.mock import Mock, patch

import scripts.audio_e2e as audio
from scripts.audio_e2e import (
    configure_test_run,
    duplex_latencies,
    measurements,
    run_pair,
)
from scripts.audio_e2e_matrix import scenarios
from scripts.simulator_audio import SimulatorAudioPin, shared_host_audio_device
from scripts.test_lifecycle import SimulatorLease, exclusive_run
from scripts.validate import (
    Fingerprint,
    Runner,
    file_fingerprint,
    fingerprints_match,
    source_manifest,
)


class Continuity(TypedDict):
    referenceOffsetSeconds: float


class MeasurementResult(TypedDict, total=False):
    captureToRenderLatencySeconds: float
    captureToRenderLatencyWithAllowanceSeconds: float


class Measurement(MeasurementResult):
    role: str
    transport: str
    scenario: str
    expectedSilence: bool
    continuityPassed: bool
    firstCaptureHostTime: float
    firstOutputHostTime: float
    localFixtureDurationSeconds: float
    continuity: Continuity


class AudioE2ELifecycleTests(unittest.TestCase):
    def test_audio_selection_rejects_the_wrong_case_even_with_one_passing_result(self) -> None:
        runner = Runner(self.root / 'test-selection')
        expected = 'AudioE2ETests/testDuplexSpeechOverNetwork'
        for method, passed in [('testDuplexSpeechOverNetwork', True), ('testSystemSessionAcceptsCallProfiles', False)]:
            stage = f'test-{method}'
            case = {'nodeType': 'Test Case', 'nodeIdentifier': f'AudioE2ETests/{method}()', 'result': 'Passed'}
            bundle = {'nodeType': 'Unit test bundle', 'name': 'RideIntercomAudioE2ETests', 'children': [case]}
            self.assertTrue(audio.xcode_tests_passed({'totalTestCount': 1, 'passedTests': 1}))
            (runner.out / f'{stage}-tests.log').write_text(json.dumps({'testNodes': [bundle]}))

            def list_tests(name: str, command: list[str], **kwargs: object) -> bool:
                self.assertEqual(kwargs['needs'], [name.removesuffix('-tests')])
                return runner.record(name, command, 'passed', 0, time.monotonic())

            with self.subTest(method=method), patch.object(runner, 'run', side_effect=list_tests):
                self.assertEqual(audio.check_audio_test_selection(runner, stage, self.root / 'native.xcresult', [expected]), passed)
            evidence = json.loads((runner.out / f'{stage}-selection.json').read_text())
            self.assertEqual(evidence['missing'], [] if passed else ['RideIntercomAudioE2ETests/' + expected])

    def test_network_audio_includes_prerequisites_in_matrix_order(self) -> None:
        selections = (
            ('quick', ['output-recovery', 'pcm16-16k-voicechat', 'output-mute'],
             ['pcm16-16k-voicechat', 'output-mute', 'output-recovery']),
            ('isolation', ['isolation-tx-restored'], ['isolation-tx-on', 'isolation-off', 'isolation-tx-restored']),
            ('full', ['local-recovery', 'peer-recovery', 'master-recovery'],
             ['master-zero', 'master-recovery', 'peer-zero', 'peer-recovery', 'local-mute', 'local-recovery']),
            ('quick', ['output-recovery'], ['output-mute', 'output-recovery']),
        )
        for index, (matrix, requested, expected) in enumerate(selections):
            argv = ['audio_e2e.py', '--output', str(self.root / f'selection-{index}'), '--matrix', matrix]
            for case in requested:
                argv.extend(('--scenario', case))
            with self.subTest(matrix=matrix, requested=requested), patch.object(sys, 'argv', argv), \
                    patch.dict(os.environ), patch.object(audio, 'simulator_resource_root', return_value=self.root), \
                    patch.object(audio, 'execute', return_value=0) as execute:
                self.assertEqual(audio.main(), 0)
                execute.assert_called_once()
                self.assertEqual([case['id'] for case in execute.call_args.args[3]], expected)

    def test_network_audio_keeps_the_whole_matrix_without_selection(self) -> None:
        argv = ['audio_e2e.py', '--output', str(self.root / 'all-cases'), '--matrix', 'smoke']
        with patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                patch.object(audio, 'simulator_resource_root', return_value=self.root), \
                patch.object(audio, 'execute', return_value=0) as execute:
            self.assertEqual(audio.main(), 0)
        self.assertEqual(execute.call_args.args[3], scenarios('smoke', 8))

    def test_internet_background_recovery_can_use_a_mac_sender(self) -> None:
        argv = ['audio_e2e.py', '--output', str(self.root / 'mac-sender'), '--matrix', 'smoke',
                '--transport', 'webrtc', '--background-recovery', '300']
        with patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                patch.object(audio, 'simulator_resource_root', return_value=self.root), \
                patch.object(audio, 'execute', return_value=0) as execute:
            self.assertEqual(audio.main(), 0)
        args = execute.call_args.args[0]
        self.assertFalse(args.two_simulators)
        self.assertEqual(args.background_recovery, 300)

    def test_isolation_matrix_changes_only_the_effect_under_test(self) -> None:
        cases = audio.scenarios('isolation', 12)
        changes = ('transmitIsolation', 'masterIsolation', 'peerIsolation')
        self.assertEqual([tuple(case[key] for key in changes) for case in cases], [
            (True, False, False), (False, False, False), (True, False, False),
            (False, True, False), (False, False, True),
        ])
        baseline = {key: value for key, value in cases[0].items() if key not in (*changes, 'id')}
        for case in cases[1:]:
            self.assertEqual({key: value for key, value in case.items() if key not in (*changes, 'id')}, baseline)

    def test_standalone_mode_carries_one_plan_for_selection_and_measurements(self) -> None:
        examples = {
            'pipeline': (('testSpeechContinuityWithoutNetwork',), ('pipeline-20ms', 'pipeline-100ms'), 180),
            'realtime': (('testRealtimeAudioLatencyAndIdentity',),
                         tuple(f'realtime-{fixture}-{codec}'
                               for fixture in ('speech-ja', 'conversation-ja', 'conversation-reply-ja')
                               for codec in ('pcm16', 'opus', 'mpeg4AACELD')), 600),
            'group': (('testEightPersonMixedRouteConversation',), ('eight-person-mixed',), 180),
            'codec': (('testTransmitChainPreservesConversationAndAcknowledgements', 'testNativeCodecsPreserveWholeSpeech'),
                      ('native-codecs', 'transmit-conversations'), 600),
            'switch-limits': (('testMeasureLiveSettingsSwitchLimits',),
                              ('switch-limits-2000ms', 'switch-limits-1000ms', 'switch-limits-500ms'), 180),
            'switches': (('testInputModeChangesRestoreTheSharedReceiveClock', 'testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio'),
                         ('live-settings', 'input-mode-recovery'), 180),
        }
        for mode, (methods, measurement_ids, timeout) in examples.items():
            argv = ['audio_e2e.py', '--output', str(self.root / mode), '--' + mode + '-only']
            with self.subTest(mode=mode), patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                    patch.object(audio, 'simulator_resource_root', return_value=self.root), \
                    patch.object(audio, 'execute', return_value=0) as execute:
                self.assertEqual(audio.main(), 0)
                plan = execute.call_args.args[4]
                self.assertEqual(plan.tests, tuple('AudioE2ETests/' + method for method in methods))
                self.assertEqual(plan.measurement_ids, measurement_ids)
                self.assertEqual(plan.timeout, timeout)
                self.assertEqual(plan.preflight, (
                    'AudioE2ETests/testTransmitIsolationRestoresTheSameNoiseReductionAfterBypass',
                    'AudioE2ETests/testReceiveIsolationKeepsItsEffectWhenEnabledAgain',
                ) if mode == 'switches' else ())

    def test_evidence_names_the_measurements_required_for_each_run(self) -> None:
        examples = [
            ('limits', ['--switch-limits-only'], ['switch-limits-2000ms', 'switch-limits-1000ms', 'switch-limits-500ms'], None),
            ('standalone', ['--switches-only'], ['live-settings', 'input-mode-recovery'], None),
            ('selected', ['--scenario', 'output-mute'], ['output-mute'], ['output-mute']),
            ('selected-recovery', ['--scenario', 'output-recovery'],
             ['output-mute', 'output-recovery'], ['output-mute', 'output-recovery']),
            ('mixed', ['--transport', 'mixed', '--matrix', 'smoke'],
             ['one-way-initial', 'local-before', 'internet-during', 'local-after'], ['default']),
            ('internet-recovery', ['--transport', 'webrtc', '--matrix', 'smoke', '--two-simulators',
                                   '--background-recovery', '300', '--configuration', 'Release'],
             ['late-internet', 'background-mic-off', 'background-internet-recovered'], ['default']),
            ('local-recovery', ['--transport', 'local', '--matrix', 'smoke', '--two-simulators',
                                '--background-recovery', '5'],
             ['late-local', 'background-mic-off', 'background-local-recovered'], ['default']),
            ('cleanup', ['--cleanup-only'], [], None),
        ]
        for name, arguments, expected_measurements, scenario_ids in examples:
            out = self.root / name
            argv = ['audio_e2e.py', '--output', str(out), *arguments]
            with self.subTest(mode=name), patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                    patch.object(audio, 'simulator_resource_root', return_value=self.root), \
                    patch.object(audio, 'source_manifest', return_value={'head': 'fixture', 'files': {}}), \
                    patch.object(audio.Runner, 'run', return_value=False), \
                    patch.object(audio.SimulatorLease, 'prepare', return_value=None), \
                    patch.object(audio.SimulatorLease, 'cleanup_host', return_value=True):
                self.assertEqual(audio.main(), 0 if name == 'cleanup' else 1)
                configuration = json.loads((out / 'configuration.json').read_text())
                self.assertEqual(configuration['expectedMeasurementIDs'], expected_measurements)
                scenarios_file = out / 'scenarios.json'
                if scenario_ids is None:
                    self.assertFalse(scenarios_file.exists())
                else:
                    self.assertEqual([case['id'] for case in json.loads(scenarios_file.read_text())], scenario_ids)

    def test_audio_scenario_errors_stop_before_creating_run_artifacts(self) -> None:
        examples = [
            (['--matrix', 'smoke', '--scenario', 'output-mute'], 'not in the smoke matrix'),
            (['--scenario', 'default', '--scenario', 'default'], 'each scenario ID only once'),
            (['--switches-only', '--scenario', 'default'], 'requires a network audio matrix'),
            (['--cleanup-only', '--scenario', 'default'], 'requires a network audio matrix'),
            (['--transport', 'mixed', '--matrix', 'smoke', '--scenario', 'default'], 'requires a network audio matrix'),
            (['--background-recovery', '300', '--transport', 'local', '--matrix', 'smoke'],
             'Use two Simulators and Debug'),
            (['--background-recovery', '301', '--transport', 'webrtc', '--matrix', 'smoke', '--two-simulators'],
             '1–300 second wait'),
            (['--background-recovery', '5', '--transport', 'local', '--matrix', 'smoke', '--two-simulators',
              '--configuration', 'Release'], 'Use two Simulators and Debug'),
        ]
        out = self.root / 'unstarted'
        for arguments, message in examples:
            with self.subTest(arguments=arguments), patch.object(sys, 'argv', ['audio_e2e.py', '--output', str(out), *arguments]):
                stderr = io.StringIO()
                with redirect_stderr(stderr), self.assertRaises(SystemExit) as error:
                    audio.main()
                self.assertEqual(error.exception.code, 2)
                self.assertIn(message, stderr.getvalue())
                self.assertFalse(out.exists())

    def test_recovery_evidence_distinguishes_background_iphone_from_the_mac(self) -> None:
        sample = {'scenario': 'late-internet', 'role': 'a', 'transport': 'webrtc', 'background': False}
        (self.root / 'sample.json').write_text(json.dumps(sample))
        self.assertEqual(measurements(self.root, ['late-internet'], 'a', 'webrtc', background=False), [sample])
        with self.assertRaisesRegex(ValueError, 'endpoint background condition'):
            measurements(self.root, ['late-internet'], 'a', 'webrtc', background=True)

    def test_interrupted_pair_still_recovers_both_simulators_after_an_audio_restore_error(self) -> None:
        for failure in (FileNotFoundError, TypeError):
            out = self.root / failure.__name__
            argv = ['audio_e2e.py', '--output', str(out), '--transport', 'local',
                    '--matrix', 'smoke', '--two-simulators', '--ephemeral']
            primary, peer = Mock(), Mock()
            primary.pin.return_value = 'fixture-audio'
            peer.pin.return_value = 'fixture-audio'
            peer.restore.side_effect = failure('synthetic command detail')

            def run(stage: str, command: list[str], *, output: Path = out, **_options: object) -> bool:
                if stage == 'runtimes':
                    (output / 'runtimes.log').write_text(json.dumps({'runtimes': [
                        {'name': 'iOS Fixture', 'version': '27.2', 'identifier': 'other-device', 'isAvailable': True,
                         'supportedDeviceTypes': [{'identifier': 'some-other-device'}]},
                        {'name': 'iOS Fixture', 'version': '27.2', 'identifier': 'ios-fixture', 'isAvailable': True,
                         'supportedDeviceTypes': [{'identifier': audio.IPHONE_DEVICE_TYPE}]},
                    ]}))
                elif stage == 'peer-create':
                    self.assertEqual(command[-2:], [audio.IPHONE_DEVICE_TYPE, 'ios-fixture'])
                    (output / 'peer-create.log').write_text('peer-simulator\n')
                return True

            def prepare(lease: SimulatorLease, runtime: str, device_type: str, **_options: object) -> str:
                self.assertEqual((runtime, device_type), ('ios-fixture', audio.IPHONE_DEVICE_TYPE))
                lease.acquired = True
                return 'primary-simulator'

            with self.subTest(failure=failure.__name__), \
                    patch.object(sys, 'argv', argv), patch.dict(os.environ), \
                    patch.object(audio, 'simulator_resource_root', return_value=out), \
                    patch.object(audio, 'source_manifest', return_value={'head': 'fixture', 'files': {}}), \
                    patch.object(audio.Runner, 'run', side_effect=run), \
                    patch.object(audio.SimulatorLease, 'prepare', autospec=True, side_effect=prepare), \
                    patch.object(audio.SimulatorLease, 'cleanup', autospec=True, return_value=True) as cleanup, \
                    patch.object(audio, 'SimulatorAudioPin', side_effect=[primary, peer]), \
                    patch.object(audio, 'build_audio_hosts', side_effect=KeyboardInterrupt):
                self.assertEqual(audio.main(), 1)
                peer.restore.assert_called_once_with()
                primary.restore.assert_called_once_with()
                self.assertEqual([call.args[1] for call in cleanup.call_args_list], ['peer-cleanup', 'cleanup'])
                results = json.loads((out / 'results.json').read_text())
                peer_result = results['peer-simulator-audio-restore']
                self.assertEqual(peer_result['status'], 'failed')
                self.assertEqual(results['simulator-audio-restore']['status'], 'passed')
                self.assertEqual(peer_result['reason'], 'Could not restore Simulator audio selection: ' + failure.__name__)

    def test_configuring_audio_hosts_requires_isolated_real_products(self) -> None:
        for platform in ('mac', 'ios'):
            products = self.root / platform
            app = products / ('Release' if platform == 'mac' else 'Release-iphonesimulator') / 'RideIntercom.app'
            info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
            info.parent.mkdir(parents=True)
            source, output = products / 'source.xctestrun', products / ('audio-pair-' + platform + '.xctestrun')
            target = {'BlueprintName': 'RideIntercomAudioE2ETests',
                      'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [target]}]}))
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom'}))
            with self.assertRaises(ValueError):
                configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {})
            self.assertFalse(output.exists())
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {'AUDIO_E2E_ROLE': 'a'})
            configured = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(configured['EnvironmentVariables']['AUDIO_E2E_ROLE'], 'a')
            self.assertEqual(configured['OnlyTestIdentifiers'], ['AudioE2ETests/testDuplexSpeechOverNetwork'])

    def test_audio_debug_and_release_use_native_isolated_configurations(self) -> None:
        from scripts.validate import ROOT
        from scripts.xcode_paths import scheme_configuration
        project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'RideIntercom.xcodeproj/project.pbxproj')]))
        objects = project['objects']
        owner = objects[project['rootObject']]
        configs = {objects[key]['name']: objects[key] for key in objects[owner['buildConfigurationList']]['buildConfigurations']}
        self.assertEqual(scheme_configuration(ROOT, 'RideIntercomAudioE2E'), 'Debug-Validation')
        release = configs['Release-Validation']['buildSettings']
        self.assertEqual(release['RIDEINTERCOM_STORAGE_NAMESPACE'], 'RideIntercom.Validation.Xcode')
        self.assertEqual(release['ENABLE_TESTABILITY'], 'YES')
        self.assertNotIn('DEBUG', release.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split())
        self.assertEqual(release.get('SWIFT_OPTIMIZATION_LEVEL', '-O'), configs['Release']['buildSettings'].get('SWIFT_OPTIMIZATION_LEVEL', '-O'))
        for target_id in owner['targets']:
            names = {objects[key]['name'] for key in objects[objects[target_id]['buildConfigurationList']]['buildConfigurations']}
            self.assertIn('Release-Validation', names)

    def test_audio_build_discovers_standard_paths_and_rejects_wrong_namespace(self) -> None:
        for configuration in ['Debug', 'Release']:
            runner = Runner(self.root / configuration)
            products = self.root / 'Xcode Default/Build/Products'
            target_dir = products / (configuration + '-Validation-iphonesimulator')
            info = target_dir / 'RideIntercom.app/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            source = products / 'RideIntercomAudioE2E_iphonesimulator_fixture.xctestrun'
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{
                'BlueprintName': 'RideIntercomAudioE2ETests',
                'TestHostPath': '__TESTROOT__/' + str(info.parent.relative_to(products))}]}]}))
            settings = {'BUILD_DIR': str(products), 'TARGET_BUILD_DIR': str(target_dir),
                'FULL_PRODUCT_NAME': 'RideIntercom.app', 'CONFIGURATION': configuration + '-Validation',
                'PLATFORM_NAME': 'iphonesimulator', 'RIDEINTERCOM_STORAGE_NAMESPACE': 'RideIntercom.Validation.Xcode'}
            def command(stage: str, argv: list[str], *, runner: Runner = runner, **kwargs: object) -> bool:
                return runner.record(stage, argv, 'passed', 0, time.monotonic())
            with patch.object(audio, 'xcode_build_settings', return_value=settings, create=True), patch.object(runner, 'run', side_effect=command):
                actual, run = audio.build_audio_host(runner, 'ios', 'platform=iOS Simulator,id=owned', configuration)
            self.assertEqual(actual, settings)
            self.assertEqual(run, source)
            argv = runner.results['build-ios']['command']
            self.assertNotIn('-derivedDataPath', argv)
            self.assertFalse(any(arg.startswith(('ENABLE_TESTABILITY=', 'RIDEINTERCOM_STORAGE_NAMESPACE=', 'CODE_SIGN_')) for arg in argv))
            self.assertEqual(argv[argv.index('-configuration') + 1], configuration + '-Validation')

    def test_shared_products_survive_cleaning_both_platforms(self) -> None:
        runner = Runner(self.root / 'evidence')
        products = self.root / 'shared-products'
        events = []
        endpoints = [('a', 'mac', 'platform=macOS'), ('b', 'ios', 'platform=iOS Simulator,id=owned')]
        def settings(root: Path | None, scheme: str | None, destination: str, configuration: str) -> dict[str, str]:
            platform = 'mac' if destination == 'platform=macOS' else 'ios'
            target = products / (configuration + ('-iphonesimulator' if platform == 'ios' else ''))
            return {'BUILD_DIR': str(products), 'TARGET_BUILD_DIR': str(target), 'FULL_PRODUCT_NAME': 'RideIntercom.app',
                'CONFIGURATION': configuration, 'PLATFORM_NAME': 'macosx' if platform == 'mac' else 'iphonesimulator',
                'RIDEINTERCOM_STORAGE_NAMESPACE': 'RideIntercom.Validation.Xcode'}
        def command(stage: str, argv: list[str], **kwargs: object) -> bool:
            destination = argv[argv.index('-destination') + 1]
            platform = 'mac' if destination == 'platform=macOS' else 'ios'
            if 'clean' in argv:
                events.append(('clean', platform))
                shutil.rmtree(products, ignore_errors=True)
            if 'build-for-testing' in argv:
                events.append(('build', platform))
                values = settings(None, None, destination, 'Debug-Validation')
                app = Path(values['TARGET_BUILD_DIR']) / 'RideIntercom.app'
                info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
                info.parent.mkdir(parents=True)
                info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
                (products / ('RideIntercomAudioE2E_' + platform + '.xctestrun')).write_bytes(plistlib.dumps({
                    'TestConfigurations': [{'TestTargets': [{'BlueprintName': 'RideIntercomAudioE2ETests',
                        'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}]}]}))
            return runner.record(stage, argv, 'passed', 0, time.monotonic())
        with patch.object(audio, 'xcode_build_settings', side_effect=settings), patch.object(runner, 'run', side_effect=command):
            built = audio.build_audio_hosts(runner, endpoints, 'Debug', clean=True)
        for values, test_run in built.values():
            self.assertTrue(test_run.exists(), 'A later clean removed an earlier platform test run')
            self.assertTrue((Path(values['TARGET_BUILD_DIR']) / 'RideIntercom.app').is_dir())
        self.assertEqual(events, [('clean', 'mac'), ('clean', 'ios'), ('build', 'mac'), ('build', 'ios')])

    def test_platform_specific_generated_runs_do_not_overwrite_each_other(self) -> None:
        products = self.root / 'products'
        products.mkdir()
        outputs = []
        limits = audio.STANDALONE_AUDIO_PLANS['switch_limits_only'].tests
        skips = [limits[0] + '()', 'OtherTests/testUnrelated']
        for platform, role in [('mac', 'a'), ('ios', 'b')]:
            folder = 'Release-Validation' + ('-iphonesimulator' if platform == 'ios' else '')
            app = products / folder / 'RideIntercom.app'
            info = app / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'StorageNamespace': 'RideIntercom.Validation.Xcode'}))
            source = products / (platform + '.xctestrun')
            source.write_bytes(plistlib.dumps({'TestConfigurations': [{'TestTargets': [{
                'BlueprintName': 'RideIntercomAudioE2ETests', 'SkipTestIdentifiers': skips,
                'TestHostPath': '__TESTROOT__/' + str(app.relative_to(products))}]}]}))
            output = configure_test_run(source, 'pair', platform, 'RideIntercom.Validation.Xcode', {'AUDIO_E2E_ROLE': role})
            outputs.append(output)
            limit_run = configure_test_run(source, 'limit', platform, 'RideIntercom.Validation.Xcode', {}, limits)
            target = plistlib.loads(limit_run.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['OnlyTestIdentifiers'], list(limits))
            self.assertEqual(target['SkipTestIdentifiers'], [skips[1]])
        self.assertNotEqual(*outputs)
        for output, role in zip(outputs, ['a', 'b']):
            target = plistlib.loads(output.read_bytes())['TestConfigurations'][0]['TestTargets'][0]
            self.assertEqual(target['EnvironmentVariables']['AUDIO_E2E_ROLE'], role)
            self.assertEqual(target['SkipTestIdentifiers'], skips)

    def test_pair_timeout_recovers_the_owned_process_without_type_error(self) -> None:
        runner = Runner(self.root / 'timeout-run')
        command = [sys.executable, '-u', '-c', 'import time; print("AUDIO_E2E_NATIVE_READY", flush=True); time.sleep(60)']
        with self.assertRaises(TimeoutError):
            run_pair(runner, [('only', command)], timeout=0.1)
        self.assertNotEqual(runner.results['only']['exit_code'], 0)

    def test_source_gate_includes_new_surface_code_and_signing_configuration(self) -> None:
        names = ['RideIntercomWatch/WatchApp.swift', 'RideIntercomWidgets/Widget.swift',
                 'RideIntercomWidgets/Widget.entitlements', 'Config/Test.xcconfig',
                 'RideIntercom.xctestplan', 'RideIntercom/RideComAppIcon.icon/icon.json',
                 'RideIntercom/Assets.xcassets/Icon.imageset/Icon.svg',
                 'RideIntercom/Assets.xcassets/Logo.imageset/Logo.pdf',
                 'RideIntercom/Assets.xcassets/Photo.imageset/Photo.jpeg',
                 'RideIntercom/RideComAppIcon.icon/Assets/Background.svg',
                 'RideIntercom/ja.lproj/InfoPlist.strings', 'RideIntercom/PrivacyInfo.xcprivacy',
                 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip']
        for name in names:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        def output(command: list[str], **kwargs: object) -> str | bytes:
            return ('\0'.join(names) + '\0').encode() if command[1] == 'ls-files' else 'fixture-head\n'
        with patch('scripts.validate.subprocess.check_output', side_effect=output):
            before = source_manifest(self.root)
            self.assertEqual(set(before['files']), set(names))
            for name in names:
                with self.subTest(changed=name):
                    (self.root / name).write_text('changed build input')
                    after = source_manifest(self.root)
                    self.assertFalse(fingerprints_match(before['files'], after['files']))
                    (self.root / name).write_text('fixture')

    def test_source_gate_rejects_all_project_changes_including_build_number(self) -> None:
        project = self.root / 'project.pbxproj'
        def capture(number: int | str, setting: str = 'Release') -> dict[str, Fingerprint]:
            project.write_text(f'CURRENT_PROJECT_VERSION = {number};\nCONFIGURATION = {setting};\nCURRENT_PROJECT_VERSION = {number};\n')
            return {'project': file_fingerprint(project)}
        before = capture(42)
        after = capture(44)
        self.assertNotEqual(before['project']['sha256'], after['project']['sha256'])
        self.assertFalse(fingerprints_match(before, after))
        self.assertFalse(fingerprints_match(after, before))
        self.assertFalse(fingerprints_match(before, capture(44, 'Debug')))
        self.assertFalse(fingerprints_match(before, {}))
        source = self.root / 'app.swift'
        source.write_text('let value = 1')
        original = {'source': file_fingerprint(source)}
        source.write_text('let value = 2')
        self.assertFalse(fingerprints_match(original, {'source': file_fingerprint(source)}))
        dotted = capture('44.2.1')
        self.assertTrue(fingerprints_match(dotted, capture('44.2.1')))
        self.assertFalse(fingerprints_match(dotted, capture('44.2.2')))

    def test_pair_initializes_native_audio_before_launching_the_other_host(self) -> None:
        ready = self.root / 'ready'
        joined = self.root / 'joined'
        first = ['first', [sys.executable, '-u', '-c',
            ('import sys,time; from pathlib import Path; time.sleep(.15); '
             'Path(sys.argv[1]).touch(); print("AUDIO_E2E_NATIVE_READY", flush=True); '
             'time.sleep(.3); assert Path(sys.argv[2]).exists()'), str(ready), str(joined)]]
        second = ['second', [sys.executable, '-c',
            'import sys; from pathlib import Path; assert Path(sys.argv[1]).exists(); Path(sys.argv[2]).touch()',
            str(ready), str(joined)]]
        runner = Runner(self.root / 'run')
        run_pair(runner, [first, second], timeout=3)
        self.assertEqual(runner.exit_code, 0)

    def test_pair_does_not_launch_another_host_after_native_setup_failure(self) -> None:
        started = self.root / 'second-started'
        runner = Runner(self.root / 'run')
        commands = [('first', [sys.executable, '-c', 'raise SystemExit(1)']),
            ('second', [sys.executable, '-c', 'import sys; from pathlib import Path; Path(sys.argv[1]).touch()', str(started)])]
        with self.assertRaisesRegex(RuntimeError, 'initialization'):
            run_pair(runner, commands, timeout=3)
        self.assertFalse(started.exists())

    def test_simulator_pair_starts_both_hosts_without_a_setup_marker(self) -> None:
        joined = self.root / 'joined'
        wait_for_peer = ('import sys, time\nfrom pathlib import Path\n'
                         'marker = Path(sys.argv[1])\ndeadline = time.monotonic() + 2\n'
                         'while not marker.exists() and time.monotonic() < deadline:\n'
                         '    time.sleep(.02)\nassert marker.exists()\n')
        commands = [('first', [sys.executable, '-c', wait_for_peer, str(joined)]),
                    ('second', [sys.executable, '-c', 'import sys; from pathlib import Path; Path(sys.argv[1]).touch()', str(joined)])]
        runner = Runner(self.root / 'run')
        run_pair(runner, commands, timeout=3, wait_for_first_native_setup=False)
        self.assertEqual(runner.exit_code, 0)

    def test_identity_matrix_preserves_full_utterance_and_codec_controls(self) -> None:
        cases = scenarios('identity', 8)
        self.assertEqual([case['codec'] for case in cases], ['mpeg4AACELD', 'pcm16', 'opus'])
        self.assertTrue(all(case['seconds'] >= 20 for case in cases))
        self.assertEqual([case['transmitIsolation'] for case in cases], [True, False, False])

    def test_duplex_latency_pairs_remote_capture_and_uses_one_global_alignment(self) -> None:
        rows: list[Measurement] = [{'role': 'a', 'transport': 'local', 'scenario': 'speech', 'expectedSilence': False, 'continuityPassed': True,
                     'firstCaptureHostTime': 100, 'firstOutputHostTime': 102.1, 'localFixtureDurationSeconds': 8,
                     'continuity': {'referenceOffsetSeconds': 1}},
                {'role': 'b', 'transport': 'local', 'scenario': 'speech', 'expectedSilence': False, 'continuityPassed': True,
                     'firstCaptureHostTime': 101, 'firstOutputHostTime': 109.08, 'localFixtureDurationSeconds': 10,
                     'continuity': {'referenceOffsetSeconds': 1}}]
        values = duplex_latencies(rows)
        self.assertAlmostEqual(values[0], 0.1)
        self.assertAlmostEqual(values[1], 0.08)
        self.assertEqual(len(rows), 2)
        for row, expected in zip(rows, (0.11, 0.09)):
            assessed = row['captureToRenderLatencyWithAllowanceSeconds']
            assert isinstance(assessed, float)
            self.assertAlmostEqual(assessed, expected)
        rows[0]['firstOutputHostTime'] += 0.2
        rows[1]['firstOutputHostTime'] += 0.01
        message = r'310\.00 ms including 10 ms alignment allowance \(300\.00 ms measured\) exceeds 125 ms'
        with self.assertRaisesRegex(ValueError, message):
            duplex_latencies(rows)
        self.assertEqual(len(rows), 2)
        for row, expected in zip(rows, (0.31, 0.10)):
            assessed = row['captureToRenderLatencyWithAllowanceSeconds']
            assert isinstance(assessed, float)
            self.assertAlmostEqual(assessed, expected)
        second_measurement = rows[1]['captureToRenderLatencySeconds']
        assert isinstance(second_measurement, float)
        self.assertAlmostEqual(second_measurement, 0.09,
                               msg='Keep every measurement even when the first endpoint fails')
        with self.assertRaises(ValueError):
            duplex_latencies(rows[:1])

    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)

    def test_latency_is_inapplicable_only_when_the_selected_measurements_are_all_silent(self) -> None:
        silence = next(case for case in scenarios('quick', 8) if case['id'] == 'output-mute')
        speech = next(case for case in scenarios('quick', 8) if case['id'] == 'output-recovery')
        muted_rows = [{'scenario': silence['id'], 'role': role, 'transport': 'local', 'expectedSilence': True}
                      for role in ('a', 'b')]
        speech_rows = [
            {'scenario': speech['id'], 'role': role, 'transport': 'local', 'expectedSilence': False,
             'continuityPassed': True, 'firstCaptureHostTime': 100.0, 'firstOutputHostTime': 101.08,
             'localFixtureDurationSeconds': 8.0, 'continuity': {'referenceOffsetSeconds': 1.0}}
            for role in ('a', 'b')
        ]
        samples = [
            ([silence], muted_rows, 'not-applicable', 0),
            ([silence, speech], muted_rows + speech_rows, 'passed', 0),
            ([silence, speech], muted_rows + speech_rows[:1], 'failed', 1),
            ([speech], [row | {'expectedSilence': True} for row in speech_rows], 'failed', 1),
        ]
        for index, (cases, rows, status, exit_code) in enumerate(samples):
            with self.subTest(status=status, index=index):
                runner = Runner(self.root / f'latency-{index}')
                audio.record_duplex_latency(runner, rows, cases, ['local'])
                self.assertEqual(runner.results['duplex-latency']['status'], status)
                self.assertEqual(runner.exit_code, exit_code)

    def test_concurrent_runs_are_rejected_and_lock_releases_on_failure(self) -> None:
        lock = self.root / 'run.lock'
        with self.assertRaisesRegex(RuntimeError, 'injected'), exclusive_run(lock):
            with self.assertRaises(BlockingIOError), exclusive_run(lock):
                self.fail('Two runs acquired the same lock')
            raise RuntimeError('injected')
        with exclusive_run(lock):
            pass

    def test_release_matrix_covers_every_exposed_audio_choice(self) -> None:
        full = scenarios('full', 8)
        self.assertEqual(len({case['id'] for case in full}), len(full))
        for codec in ['pcm16', 'opus', 'mpeg4AACELD']:
            self.assertEqual({c['format'] for c in full if c['codec'] == codec}, {'mono16k', 'mono24k', 'mono48k'})
        self.assertEqual({c['profile'] for c in full}, {'standard', 'speakerDefault', 'echoCancelledInput', 'voiceChat'})
        session_modes = {'standard': ('standard', False), 'speakerDefault': ('standard', True),
                         'echoCancelledInput': ('standard', True), 'voiceChat': ('voiceChat', False)}
        actual_sessions = {(*session_modes[c['profile']], c.get('speaker', False) or c['profile'] == 'speakerDefault')
                           for c in full}
        self.assertEqual(actual_sessions, {
            ('standard', False, False), ('standard', True, False),
            ('standard', False, True), ('standard', True, True),
            ('voiceChat', False, False), ('voiceChat', False, True),
        })
        self.assertEqual({c['vad'] for c in full}, {'lowNoise', 'standard', 'noisy'})
        for key in ['transmitIsolation', 'masterIsolation', 'peerIsolation', 'duck', 'localMute', 'outputMute']:
            self.assertEqual({c[key] for c in full}, {False, True}, key)
        for rate, aac in [('mono16k', {48000}), ('mono24k', {32000, 64000}), ('mono48k', {48000, 128000})]:
            for codec, limits in [('mpeg4AACELD', aac), ('opus', {48000, 128000})]:
                self.assertTrue(limits <= {c['bitRate'] for c in full if c['codec'] == codec and c['format'] == rate})
        self.assertLess(sum(c['seconds'] for c in scenarios('quick', 8)), 40)

    def test_acceptance_requires_every_scenario_from_the_expected_endpoint(self) -> None:
        def write(name: str, scenario: str, role: str = 'a', transport: str = 'local') -> None:
            (self.root / name).write_text(json.dumps({'scenario': scenario, 'role': role, 'transport': transport}))
        write('one.json', 'voice')
        with self.assertRaisesRegex(ValueError, 'Missing'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'voice')
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'mute', role='b')
        with self.assertRaisesRegex(ValueError, 'different endpoint'):
            measurements(self.root, ['voice', 'mute'], 'a', 'local')
        write('two.json', 'mute')
        self.assertEqual(len(measurements(self.root, ['voice', 'mute'], 'a', 'local')), 2)

    def test_recorded_host_path_cannot_authorize_stopping_a_gui_process(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.state = {'executable': str(self.root / 'Default DerivedData/RideIntercom.app/Contents/MacOS/RideIntercom')}
        with patch('scripts.test_lifecycle.matching_processes', return_value=[123]), \
             patch('scripts.test_lifecycle.stop_executable', return_value=[], create=True) as stop, \
             patch('scripts.test_lifecycle.os.kill') as kill:
            self.assertFalse(lease.cleanup_host('recorded'))
        stop.assert_not_called()
        kill.assert_not_called()
        self.assertEqual(runner.results['recorded-host']['status'], 'failed')
        self.assertIn('ownership', runner.results['recorded-host']['reason'])

    def test_create_failure_is_recovered_by_exact_journaled_name(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json', stage='peer')
        lease.reserve('owned-unique-name')
        # simctl may create the device before its caller is interrupted, so the
        # journal must already contain the name even when no UUID was returned.
        def interrupted_create(stage: str, command: list[str], *, timeout: int) -> bool:
            self.assertEqual(stage, 'peer-create')
            self.assertEqual(command, ['xcrun', 'simctl', 'create', 'owned-unique-name', 'phone', 'ios'])
            self.assertEqual(timeout, 60)
            self.assertEqual(json.loads(lease.journal.read_text()), {'name': 'owned-unique-name', 'reusable': False})
            return False

        with patch.object(runner, 'run', side_effect=interrupted_create), self.assertRaisesRegex(RuntimeError, 'peer-create'):
            lease.create_reserved('ios', 'phone')
        devices = [{'name': 'owned-unique-name', 'udid': 'ours', 'state': 'Booted'},
                   {'name': 'owned-unique-name-extra', 'udid': 'other', 'state': 'Booted'}]
        calls = []
        with patch('scripts.test_lifecycle.simulator_devices', side_effect=[devices, [devices[1]]]), \
             patch.object(runner, 'run', side_effect=lambda name, command, **kw: calls.append(command) or True):
            SimulatorLease(runner, lease.journal).cleanup('recovery')
        self.assertEqual(calls, [['xcrun', 'simctl', 'shutdown', 'ours'], ['xcrun', 'simctl', 'delete', 'ours']])
        self.assertFalse(lease.journal.exists())

    def test_delete_is_attempted_even_when_shutdown_fails_and_failure_is_retained(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.reserve('owned')
        calls = []
        def run(name: str, command: list[str], **kw: object) -> bool:
            calls.append(command)
            return command[2] == 'delete'
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'owned', 'udid': 'ours', 'state': 'Booted'}]), patch.object(runner, 'run', side_effect=run):
            self.assertFalse(lease.cleanup('final'))
        self.assertEqual([c[2] for c in calls], ['shutdown', 'delete'])
        self.assertTrue(lease.journal.exists())

    def test_cleanup_rejects_successful_commands_that_leave_the_wrong_device_state(self) -> None:
        devices = [{'name': 'owned-fixture', 'udid': 'ours', 'state': 'Booted'}]
        for reusable, final_state in [(True, 'Booted'), (False, 'Shutdown')]:
            with self.subTest(reusable=reusable):
                runner = Runner(self.root / f'evidence-{reusable}')
                lease = SimulatorLease(runner, self.root / f'lease-{reusable}.json')
                lease.reserve('owned-fixture', reusable=reusable)
                lease.identify('ours')
                remaining = [devices[0] | {'state': final_state}]
                with patch('scripts.test_lifecycle.simulator_devices', side_effect=[devices, remaining]), \
                     patch.object(runner, 'run', return_value=True):
                    self.assertFalse(lease.cleanup('final'))
                self.assertEqual(runner.results['final-verify']['status'], 'failed')
                self.assertEqual(runner.exit_code, 1)
                self.assertEqual(SimulatorLease(runner, lease.journal).state['udid'], 'ours')

    def test_reusable_device_is_stopped_and_remains_owned_for_the_next_run(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        lease.reserve('one-managed-device', reusable=True)
        lease.identify('our-uuid')
        calls = []
        device = {'name': 'one-managed-device', 'udid': 'our-uuid', 'state': 'Booted'}
        with patch('scripts.test_lifecycle.simulator_devices', side_effect=[[device], [device | {'state': 'Shutdown'}]]), \
             patch.object(runner, 'run', side_effect=lambda name, command, **kw: calls.append(command) or True):
            self.assertTrue(lease.cleanup('final'))
        self.assertEqual(calls, [['xcrun', 'simctl', 'shutdown', 'our-uuid']])
        self.assertEqual(SimulatorLease(runner, lease.journal).state['udid'], 'our-uuid')

    def test_missing_journal_adopts_latest_device_and_removes_only_idle_managed_duplicates(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        devices = [{'name': name, 'udid': uid, 'state': 'Shutdown', 'runtime': 'ios',
                        'deviceTypeIdentifier': 'phone', 'isAvailable': True, 'lastUsedAt': date}
                   for name, uid, date in [('RideIntercom Audio E2E 12345678', 'old', '2026-01'),
                                           ('RideIntercom Audio E2E abcdef12', 'new', '2026-10'),
                                           ('iPhone 17', 'personal', '2026-11'),
                                           ('RideIntercom Recovery Tests', 'recovery', '')]]
        with patch('scripts.test_lifecycle.simulator_devices', return_value=devices), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertEqual(lease.prepare('ios', 'phone'), 'new')
        self.assertEqual([c.args[1] for c in run.call_args_list],
                         [['xcrun', 'simctl', 'delete', 'old'], ['xcrun', 'simctl', 'delete', 'recovery']])
        self.assertEqual(SimulatorLease(runner, lease.journal).state['udid'], 'new')
        self.assertTrue((runner.out / 'simulator-inventory.json').exists())

    def test_another_device_type_keeps_its_own_managed_simulator(self) -> None:
        # The iOS validation leases an iPhone and an iPad; preparing one must not delete the other.
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        devices = [{'name': 'RideIntercom Audio E2E 12345678', 'udid': 'pad', 'state': 'Shutdown', 'runtime': 'ios',
                        'deviceTypeIdentifier': 'pad', 'isAvailable': True, 'lastUsedAt': '2026-10'},
                   {'name': 'RideIntercom Audio E2E abcdef12', 'udid': 'phone', 'state': 'Shutdown', 'runtime': 'ios',
                        'deviceTypeIdentifier': 'phone', 'isAvailable': True, 'lastUsedAt': '2026-09'}]
        with patch('scripts.test_lifecycle.simulator_devices', return_value=devices), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertEqual(lease.prepare('ios', 'phone'), 'phone')
        run.assert_not_called()

    def test_busy_managed_device_blocks_reconciliation_without_deleting_anything(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'RideIntercom Audio E2E 12345678', 'udid': 'busy', 'state': 'Booted'}]), \
             patch.object(runner, 'run') as run, self.assertRaisesRegex(RuntimeError, 'in use'):
            lease.prepare('ios', 'phone')
        run.assert_not_called()
        self.assertFalse(lease.acquired)

    def test_cleanup_failure_prevents_creating_a_replacement(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'RideIntercom Audio E2E 12345678', 'udid': 'old', 'state': 'Shutdown', 'isAvailable': False}]), \
             patch.object(runner, 'run', return_value=False) as run, self.assertRaisesRegex(RuntimeError, 'delete'):
            lease.prepare('ios', 'phone')
        self.assertEqual([c.args[1][2] for c in run.call_args_list], ['delete'])

    def test_inventory_is_checked_before_creation_and_creation_is_journaled(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        def create(name: str, command: list[str], **kwargs: object) -> bool:
            self.assertTrue((runner.out / 'simulator-inventory.json').exists())
            self.assertEqual(json.loads(lease.journal.read_text())['name'], command[3])
            (runner.out / 'simulator-create.log').write_text('created-uuid\n')
            return True
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[]), \
             patch.object(runner, 'run', side_effect=create):
            self.assertEqual(lease.prepare('ios', 'phone'), 'created-uuid')
        self.assertTrue(lease.acquired)
        self.assertTrue(lease.state['reusable'])

    def test_cleanup_only_removes_orphans_without_creating_a_device(self) -> None:
        runner = Runner(self.root / 'evidence')
        lease = SimulatorLease(runner, self.root / 'lease.json')
        with patch('scripts.test_lifecycle.simulator_devices', return_value=[
                {'name': 'RideIntercom Validation old-run', 'udid': 'old', 'state': 'Shutdown'}]), \
             patch.object(runner, 'run', return_value=True) as run:
            self.assertIsNone(lease.prepare(None, None, delete_all=True))
        self.assertEqual([c.args[1] for c in run.call_args_list], [['xcrun', 'simctl', 'delete', 'old']])
        self.assertFalse(lease.journal.exists())

    def test_previous_mode_only_checks_old_host_without_touching_simulator(self) -> None:
        runner = Runner(self.root / 'evidence')
        old = SimulatorLease(runner, self.root / 'ephemeral.json')
        old.reserve('RideIntercom Audio E2E 12345678')
        old.identify('reused')
        old.state['executable'] = str(self.root / 'old-host')
        old.save()
        with patch('scripts.test_lifecycle.matching_processes', return_value=[]) as matches, \
             patch('scripts.test_lifecycle.os.kill') as kill, \
             patch('scripts.test_lifecycle.simulator_devices') as inventory, \
             patch.object(runner, 'run') as run:
            self.assertTrue(old.cleanup_host('previous-mode'))
        matches.assert_called_once_with(str(self.root / 'old-host'))
        kill.assert_not_called()
        inventory.assert_not_called()
        run.assert_not_called()
        self.assertNotIn('executable', old.state)

    def test_runner_sigterm_stops_child_and_executes_final_cleanup_without_ai(self) -> None:
        marker = self.root / 'child.pid'
        cleaned = self.root / 'cleaned'
        child = f'import os,time;open({str(marker)!r},"w").write(str(os.getpid()));time.sleep(60)'
        code = ('import signal\nfrom scripts.validate import Fingerprint, Runner, file_fingerprint, fingerprints_match\n'
                'def interrupt(*args): raise KeyboardInterrupt\n'
                'signal.signal(signal.SIGTERM, interrupt)\n'
                f'r=Runner({str(self.root / "run")!r})\n'
                'try:\n'
                f' r.run("child",[{sys.executable!r},"-c",{child!r}])\n'
                'finally:\n'
                f' open({str(cleaned)!r},"w").write("done")\n')
        process = subprocess.Popen([sys.executable, '-c', code], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        import time
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGTERM)
            self.assertNotEqual(process.wait(timeout=5), 0)
            self.assertTrue(cleaned.exists())
            state = subprocess.run(['ps', '-o', 'stat=', '-p', marker.read_text()], capture_output=True, text=True, check=False).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'), state)
        finally:
            if process.poll() is None:
                process.kill(); process.wait()



class SimulatorAudioDeviceTests(unittest.TestCase):
    """The Simulator's duplex I/O opens only when input and output share one host device."""
    DEVICES: ClassVar[dict[str, list[dict[str, str]]]] = {'inputDevices': [{'uid': 'wave', 'name': 'Wave'}, {'uid': 'mic', 'name': 'Display Mic'}],
               'outputDevices': [{'uid': 'wave', 'name': 'Wave'}, {'uid': 'speaker', 'name': 'Display Speaker'}]}
    HOST: ClassVar[list[dict[str, str | int]]] = [{'_name': 'Wave', 'coreaudio_device_input': 1, 'coreaudio_device_output': 2,
             'coreaudio_device_srate': 48000, 'coreaudio_default_audio_input_device': 'spaudio_yes'},
            {'_name': 'Display Mic', 'coreaudio_device_input': 1, 'coreaudio_device_srate': 96000},
            {'_name': 'Display Speaker', 'coreaudio_device_output': 8, 'coreaudio_device_srate': 96000,
             'coreaudio_default_audio_output_device': 'spaudio_yes'}]

    def test_selects_the_single_48_khz_device_with_both_directions(self) -> None:
        self.assertEqual(shared_host_audio_device(self.DEVICES, self.HOST), 'wave')

    def test_malformed_audio_command_response_fails_as_a_type_error(self) -> None:
        pin = SimulatorAudioPin('fixture-simulator')
        pin.original = ('systemDefault', 'systemDefault')
        response = subprocess.CompletedProcess([], 0, stdout='[]')
        with patch('scripts.simulator_audio.subprocess.run', return_value=response), \
                self.assertRaisesRegex(TypeError, 'Invalid audio device command response'):
            pin.restore()

    def test_rejects_hosts_without_one_unambiguous_duplex_device(self) -> None:
        only_split = [item for item in self.HOST if item['_name'] != 'Wave']
        with self.assertRaises(ValueError):
            shared_host_audio_device(self.DEVICES, only_split)
        twins = {key: value + [{'uid': 'other', 'name': 'Other'}] for key, value in self.DEVICES.items()}
        other = dict(self.HOST[0], _name='Other')
        other.pop('coreaudio_default_audio_input_device')
        self.assertEqual(shared_host_audio_device(twins, self.HOST + [other]), 'wave',
                         'The host default input wins over another eligible device')
        plain = [dict(item) for item in self.HOST]
        plain[0].pop('coreaudio_default_audio_input_device')
        with self.assertRaises(ValueError):
            shared_host_audio_device(twins, plain + [other])

    def test_pins_both_directions_and_restores_the_original_selection(self) -> None:
        calls = []
        state = {'audioInputDevice': {'systemDefault': {}}, 'audioOutputDevice': {'systemDefault': {}}, 'volume': 60}
        devices = {key: value + [{'uid': 'other', 'name': 'Other'}] for key, value in self.DEVICES.items()}
        host = [dict(item) for item in self.HOST]
        host[0].pop('coreaudio_default_audio_input_device')
        host.append(dict(host[0], _name='Other'))

        def run(args: list[str]) -> Mapping[str, object]:
            calls.append(args)
            if args[:4] == ['xcrun', 'devicectl', 'device', 'info']:
                return dict(state)
            if args[:4] == ['xcrun', 'devicectl', 'list', 'audioDevices']:
                return devices
            if args[0] == 'system_profiler':
                return {'SPAudioDataType': [{'_items': host}]}
            selected = {'audioInputDevice': args[args.index('--input-device') + 1],
                        'audioOutputDevice': args[args.index('--output-device') + 1]}
            for key, value in selected.items():
                state[key] = {'systemDefault': {}} if value == 'systemDefault' else {'device': {'_0': value}}
            return {}

        pin = SimulatorAudioPin('sim', run)
        with (
            patch.dict(os.environ, RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE='Display Mic'),
            self.assertRaisesRegex(ValueError, 'RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE'),
        ):
            pin.pin()
        self.assertFalse(any('--input-device' in args for args in calls))
        with patch.dict(os.environ, RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE='Other'):
            self.assertEqual(pin.pin(), 'other')
        self.assertEqual(state['audioInputDevice'], {'device': {'_0': 'other'}})
        self.assertEqual(state['audioOutputDevice'], {'device': {'_0': 'other'}})
        pin.restore()
        self.assertEqual(state['audioInputDevice'], {'systemDefault': {}})
        self.assertEqual(state['audioOutputDevice'], {'systemDefault': {}})
        settings = [args for args in calls if args[:4] == ['xcrun', 'devicectl', 'device', 'settings']]
        self.assertEqual(len(settings), 2)
        pin.restore()
        self.assertEqual(len([args for args in calls if args[:4] == ['xcrun', 'devicectl', 'device', 'settings']]), 2,
                         'Restore is idempotent')


if __name__ == '__main__':
    unittest.main()
