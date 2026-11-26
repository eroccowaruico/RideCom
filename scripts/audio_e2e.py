#!/usr/bin/env python3
"""Real speech test with Mac and/or iPhone Simulator. Artifacts and test data are isolated."""

from __future__ import annotations

import argparse
import json
import math
import os
import plistlib
import signal
import socket
import subprocess
import sys
import time
import uuid
from collections.abc import Mapping, Sequence
from datetime import datetime
from pathlib import Path
from types import FrameType

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.audio_e2e_matrix import (
    MIXED_AUDIO_MEASUREMENT_IDS,
    SCENARIO_PREREQUISITES,
    STANDALONE_AUDIO_PLANS,
    AudioCase,
    StandaloneAudioPlan,
    scenarios,
)
from scripts.simulator_audio import SimulatorAudioPin
from scripts.test_lifecycle import (
    IPHONE_DEVICE_TYPE,
    SimulatorLease,
    exclusive_run,
    latest_runtime,
    process_snapshot,
    simulator_resource_root,
)
from scripts.validate import (
    ROOT,
    Runner,
    fingerprints_match,
    source_manifest,
    test_host_metadata,
    xcode_tests_passed,
)
from scripts.xcode_paths import (
    scheme_configuration,
    select_test_run,
    xcode_build_settings,
    xcode_test_result,
)

AUDIO_TEST_TARGET = 'RideIntercomAudioE2ETests'
DUPLEX_TEST = 'AudioE2ETests/testDuplexSpeechOverNetwork'


def check_audio_test_selection(runner: Runner, stage: str, bundle: Path, identifiers: Sequence[str]) -> bool:
    return runner.check_test_selection(stage, bundle, [f'{AUDIO_TEST_TARGET}/{identifier}' for identifier in identifiers])


def configure_test_run(source: Path, purpose: str, platform: str, namespace: str,
                       environment: dict[str, str], identifiers: Sequence[str] | None = None) -> Path:
    data = plistlib.loads(source.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if len(targets) != 1 or targets[0]['BlueprintName'] != AUDIO_TEST_TARGET:
        raise ValueError('Expected the dedicated audio E2E test target')
    test_host_metadata(source, namespace)
    targets[0].setdefault('EnvironmentVariables', {}).update(environment)
    limits = STANDALONE_AUDIO_PLANS['switch_limits_only'].tests
    if identifiers and tuple(identifiers) == limits:
        targets[0]['SkipTestIdentifiers'] = [
            name for name in targets[0].get('SkipTestIdentifiers', []) if name.removesuffix('()') not in limits
        ]
    targets[0]['OnlyTestIdentifiers'] = identifiers or [DUPLEX_TEST]
    # Mac and Simulator now share Xcode's product root. Keep distinct files
    # beside their products so __TESTROOT__ stays valid for both endpoints.
    destination = source.parent / f'audio-{purpose}-{platform}.xctestrun'
    destination.write_bytes(plistlib.dumps(data))
    return destination


def build_audio_host(runner: Runner, platform: str, destination: str,
                     optimization: str) -> tuple[dict[str, str], Path]:
    configuration = optimization + '-Validation'
    if optimization == 'Debug' and scheme_configuration(ROOT, 'RideIntercomAudioE2E') != configuration:
        raise ValueError('Audio E2E TestAction must use the native Debug validation configuration')
    settings = xcode_build_settings(ROOT, 'RideIntercomAudioE2E', destination, configuration)
    (runner.out / ('build-settings-' + platform + '.json')).write_text(json.dumps(settings, indent=2) + '\n')
    command = ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj',
        '-scheme', 'RideIntercomAudioE2E', '-configuration', configuration, '-destination', destination]
    if not runner.run('build-' + platform, command):
        raise RuntimeError('Audio E2E build failed')
    test_run = select_test_run(settings, 'RideIntercomAudioE2E')
    if not runner.check_test_host('host-preflight-' + platform, test_run, settings['RIDEINTERCOM_STORAGE_NAMESPACE']):
        raise RuntimeError('Audio E2E host isolation check failed')
    if test_run is None:
        raise RuntimeError('Audio E2E host isolation check accepted a missing test run')
    return settings, test_run


def build_audio_hosts(runner: Runner, endpoints: list[tuple[str, str, str]], optimization: str,
                      clean: bool = False) -> dict[str, tuple[dict[str, str], Path]]:
    destinations = {platform: destination for _, platform, destination in endpoints}
    # Both SDKs share Xcode's product root. Finish every clean before building
    # either endpoint, so the second SDK cannot remove the first SDK's products.
    if clean:
        for platform, destination in destinations.items():
            command = ['xcodebuild', 'clean', '-project', 'RideIntercom.xcodeproj',
                '-scheme', 'RideIntercomAudioE2E', '-configuration', optimization + '-Validation', '-destination', destination]
            if not runner.run('clean-' + platform, command):
                raise RuntimeError('Audio E2E clean failed')
    products = {}
    for platform, destination in destinations.items():
        products[platform] = build_audio_host(runner, platform, destination, optimization)
    return products


def measurements(folder: Path, expected_ids: Sequence[str], role: str, transport: str,
                 *, background: bool | None = None) -> list[dict[str, object]]:
    rows = [json.loads(path.read_text()) for path in folder.glob('*.json') if path.name != 'manifest.json']
    rows = [row for row in rows if 'scenario' in row]
    actual = [row.get('scenario') for row in rows]
    if len(actual) != len(expected_ids) or set(actual) != set(expected_ids):
        raise ValueError('Missing or duplicate per-scenario speech measurements')
    if any(row.get('role') != role or row.get('transport') != transport for row in rows):
        raise ValueError('Speech measurements belong to a different endpoint or transport')
    if background is not None and any(row.get('background') is not background for row in rows):
        raise ValueError('Speech measurements do not match the endpoint background condition')
    return rows


def duplex_latencies(rows: Sequence[Mapping[str, object]]) -> list[float]:
    """Mac and its Simulator share the monotonic host clock, unlike two phones.

    Resolve the known repeating fixture phase ONCE per recording. The bounded
    production queues are much shorter than a fixture period; a per-window fit
    would conceal changes in playback delay and is deliberately not used.
    """
    values, failures = [], []
    for row in rows:
        if row['expectedSilence']:
            continue
        if not row.get('continuityPassed'):
            failures.append('Latency is unavailable without matched speech output')
            continue
        remote = [other for other in rows if other['scenario'] == row['scenario']
                  and other['transport'] == row['transport'] and other['role'] != row['role']]
        if len(remote) != 1:
            failures.append('Latency requires both measured endpoints')
            continue
        sender = remote[0]
        period = sender['localFixtureDurationSeconds']
        output_time = row['firstOutputHostTime']
        capture_time = sender['firstCaptureHostTime']
        continuity = row['continuity']
        if not isinstance(continuity, dict):
            raise TypeError('Invalid continuity measurement')
        offset = continuity['referenceOffsetSeconds']
        if not isinstance(period, (int, float)) or not isinstance(output_time, (int, float)) or not isinstance(capture_time, (int, float)) or not isinstance(offset, (int, float)):
            raise TypeError('Invalid capture/render timing')
        delay = output_time - capture_time - offset
        if not math.isfinite(period) or period < 2 or not math.isfinite(delay):
            failures.append('Invalid capture/render timing')
            continue
        delay -= round(delay / period) * period
        if not isinstance(row, dict):
            raise TypeError('Measurement row must be mutable')
        row['captureToRenderLatencySeconds'] = delay
        values.append(delay)
        # Retain a 10 ms allowance for alignment resolution in the 125 ms budget.
        allowance = 0.01
        comparison = delay + allowance
        row['captureToRenderLatencyWithAllowanceSeconds'] = comparison
        endpoint = f"{row['transport']} {row['scenario']} {row['role']}"
        if delay < -allowance:
            failures.append(f"{endpoint}: invalid negative measured latency of {delay * 1000:.2f} ms")
        elif comparison > 0.125:
            failures.append(f"{endpoint}: {comparison * 1000:.2f} ms including 10 ms alignment allowance "
                            f"({delay * 1000:.2f} ms measured) exceeds 125 ms budget")
    if failures:
        raise ValueError('; '.join(failures))
    return values


def record_duplex_latency(runner: Runner, rows: Sequence[Mapping[str, object]],
                          cases: Sequence[AudioCase], transports: Sequence[str]) -> None:
    started = time.monotonic()
    # Both endpoints receive the same scenario settings. Check the result against
    # those settings before deciding whether any speech latency was required.
    expected = {
        (transport, case['id'], role):
            case['localMute'] or case['outputMute'] or case['masterVolume'] == 0 or case['peerVolume'] == 0
        for transport in transports for case in cases for role in ('a', 'b')
    }
    try:
        observed = {(row['transport'], row['scenario'], row['role']): row['expectedSilence'] for row in rows}
        if not expected or len(observed) != len(rows) or observed.keys() != expected.keys():
            raise ValueError('Latency evidence does not cover the selected transports, scenarios and endpoints')
        if any(observed[key] is not silent for key, silent in expected.items()):
            raise ValueError('Latency evidence does not match the selected speech and silence conditions')
        required = sum(not silent for silent in expected.values())
        if required == 0:
            runner.record('duplex-latency', [], 'not-applicable', None, started, 'Selected scenarios expect only silence')
            return
        measured = duplex_latencies(rows)
        if len(measured) != required:
            raise ValueError('Missing latency measurements for speech directions')
        runner.record('duplex-latency', [], 'passed', 0, started, f'Measured all {required} speech directions')
    except (KeyError, TypeError, ValueError) as error:
        runner.record('duplex-latency', [], 'failed', 1, started, str(error))


def run_pair(runner: Runner, commands: Sequence[Sequence[str | list[str]]], timeout: float,
             *, wait_for_first_native_setup: bool = True) -> None:
    processes = []
    started = time.monotonic()
    try:
        for name, command in commands:
            if not isinstance(name, str) or not isinstance(command, list) or not all(isinstance(arg, str) for arg in command):
                raise TypeError('Invalid audio endpoint command')
            log = (runner.out / (name + '.log')).open('w')
            try:
                process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                log.close()
            processes.append((name, command, process, None))
            original = process_snapshot().get(process.pid)
            processes[-1] = (name, command, process, original)
            if wait_for_first_native_setup and len(processes) == 1 and len(commands) > 1:
                # Both endpoints share the Mac's CoreAudio service. Initialize
                # their native graphs in order, then measure simultaneous media.
                # This is setup readiness, never an added audio-path delay.
                while 'AUDIO_E2E_NATIVE_READY' not in (runner.out / (name + '.log')).read_text(errors='replace'):
                    if process.poll() is not None:
                        raise RuntimeError('Audio endpoint exited before native initialization completed')
                    if time.monotonic() - started > min(timeout, 30):
                        raise TimeoutError('Audio endpoint native initialization exceeded its deadline')
                    time.sleep(0.05)
        while any(p.poll() is None for _, _, p, _ in processes):
            if time.monotonic() - started > timeout:
                raise TimeoutError('Audio endpoints exceeded their deadline')
            time.sleep(0.2)
    finally:
        for name, command, process, original in processes:
            cleanup = Runner.stop(process, original) if process.poll() is None else ''
            runner.record(name, command, 'passed' if process.returncode == 0 and not cleanup else 'failed', process.returncode, started, cleanup)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug', help='Use Release for shipping-performance measurements; thresholds are identical')
    parser.add_argument('--clean-build', action='store_true', help='Clean test products before building, preserving bundle identifiers and signing')
    parser.add_argument('--ephemeral', action='store_true', help='Delete the owned simulator after this run (CI)')
    parser.add_argument('--two-simulators', action='store_true', help='Run both network audio endpoints on iPhone Simulators')
    parser.add_argument('--background-recovery', type=int, metavar='WAIT_SECONDS',
                        help='Wait muted in the background, then measure late speech and audio after a route outage')
    parser.add_argument('--cleanup-only', action='store_true', help='Recover managed devices and report old running hosts without stopping unknown owners')
    parser.add_argument('--transport', choices=['local', 'webrtc', 'mixed', 'all'], default='all')
    parser.add_argument('--saved-group-start', action='store_true', help='Start Local audio from a saved group when Apple credential verification is unavailable')
    parser.add_argument('--saved-contact-start', action='store_true',
                        help='Turn off Local and start Internet audio from a saved contact on each endpoint')
    parser.add_argument('--registration-recovery', action='store_true',
                        help='Start a saved call on Local, then supply the Internet registration result during the call')
    credentials = parser.add_mutually_exclusive_group()
    credentials.add_argument('--credential-recovery', action='store_true',
                             help='Start with a rejected Internet credential and measure duplex audio after registration')
    credentials.add_argument('--credential-continuation', action='store_true',
                             help='Measure duplex audio while an established WebRTC session needs continuation')
    parser.add_argument('--unanswered-internet', action='store_true', help='Keep both Internet connection requests pending during saved-group Local audio')
    parser.add_argument('--matrix', choices=['smoke', 'quick', 'full', 'identity', 'isolation'], default='quick')
    parser.add_argument('--scenario', metavar='ID', action='append', default=[],
                        help='Run this scenario and its prerequisites; repeat to select multiple cases')
    parser.add_argument('--speech-pair', choices=['english', 'japanese', 'conversation'], default='english')
    parser.add_argument('--switch-limits-only', action='store_true', help='Measure live setting changes at three intervals without changing acceptance')
    parser.add_argument('--switches-only', action='store_true', help='Live codec, format and effect changes with bounded silence and click checks')
    parser.add_argument('--codec-only', action='store_true', help='Native codec identity across four speech fixtures and all supported formats')
    parser.add_argument('--group-only', action='store_true', help='Eight participants with mixed codecs, delayed relay routes and real rendered audio')
    parser.add_argument('--realtime-only', action='store_true', help='Measure real iOS input, VAD, streaming codecs and output against the 125 ms budget')
    parser.add_argument('--pipeline-only', action='store_true', help='Measure the iOS mixer/codec/output without network or VAD')
    parser.add_argument('--seconds', type=int, default=8)
    parser.add_argument('--codec', choices=['default', 'pcm16', 'opus', 'mpeg4AACELD'], default='default')
    parser.add_argument('--isolation', choices=['default', 'off'], default='default')
    args = parser.parse_args()
    if not 6 <= args.seconds <= 600:
        parser.error('--seconds must be between 6 and 600')
    standalone_plans = [plan for mode, plan in STANDALONE_AUDIO_PLANS.items() if getattr(args, mode)]
    if len(standalone_plans) > 1:
        parser.error('Choose one standalone audio test mode')
    standalone = next(iter(standalone_plans), None)
    if args.matrix == 'isolation' and (standalone or args.cleanup_only or args.isolation == 'off'):
        parser.error('The isolation matrix requires a network run with independent TX and RX settings')
    if args.background_recovery is not None and (
        not 1 <= args.background_recovery <= 300 or args.transport not in ('local', 'webrtc')
        or (args.transport == 'local' and (not args.two_simulators or args.configuration != 'Debug'))
        or args.matrix != 'smoke' or standalone or args.cleanup_only
        or args.saved_group_start or args.scenario
    ):
        parser.error('--background-recovery requires a 1–300 second wait and the smoke matrix for Local or WebRTC. '
                     'Use two Simulators and Debug for Local listener interruption.')
    if args.two_simulators and standalone:
        parser.error('--two-simulators requires a network audio test')
    if args.saved_group_start and (args.transport != 'local' or standalone):
        parser.error('--saved-group-start requires --transport local with the network audio test')
    if args.saved_contact_start and (args.transport != 'webrtc' or standalone or args.cleanup_only
                                     or args.background_recovery is not None):
        parser.error('--saved-contact-start requires --transport webrtc with the foreground network audio test')
    if args.unanswered_internet and (not args.saved_group_start or args.matrix != 'smoke' or args.seconds > 10):
        parser.error('--unanswered-internet requires --saved-group-start --matrix smoke and 6–10 seconds')
    if args.transport == 'mixed' and (args.configuration != 'Debug' or args.matrix != 'smoke' or standalone):
        parser.error('Use --transport mixed with Debug and --matrix smoke for the Local/WebRTC recovery test')
    if args.registration_recovery and (args.transport != 'mixed' or not args.two_simulators or args.cleanup_only):
        parser.error('--registration-recovery requires --transport mixed --matrix smoke --two-simulators')
    if (args.credential_recovery or args.credential_continuation) and (
        args.transport != 'webrtc' or args.matrix != 'smoke' or not args.two_simulators
        or standalone or args.cleanup_only or args.background_recovery is not None
    ):
        parser.error('Credential tests require --transport webrtc --matrix smoke --two-simulators')
    if args.speech_pair == 'conversation' and args.seconds < 20:
        parser.error('Conversation coverage requires --seconds 20 or longer')
    cases = [] if standalone or args.cleanup_only else scenarios(args.matrix, args.seconds)
    if args.scenario:
        if standalone or args.cleanup_only or args.transport == 'mixed':
            parser.error('--scenario requires a network audio matrix (local, webrtc, or all)')
        selected = set(args.scenario)
        if len(selected) != len(args.scenario):
            parser.error('Specify each scenario ID only once')
        unknown = selected.difference(case['id'] for case in cases)
        if unknown:
            parser.error(f'Scenario IDs not in the {args.matrix} matrix: {", ".join(sorted(unknown))}')
        for case in reversed(cases):
            if case['id'] in selected:
                selected.update(SCENARIO_PREREQUISITES.get(case['id'], ()))
        cases = [case for case in cases if case['id'] in selected]
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    out = (args.output or ROOT / '.validation' / ('audio-e2e-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))).resolve()
    if out == ROOT:
        parser.error('Use a separate evidence folder within .validation or another explicit output location')
    runner = Runner(out)
    resource_root = simulator_resource_root()
    try:
        with exclusive_run(resource_root / 'run.lock'):
            return execute(args, runner, resource_root, cases, standalone)
    except BlockingIOError:
        runner.record('exclusive-run', [], 'failed', 1, time.monotonic(), 'Another audio E2E run is active')
        return 1


def execute(args: argparse.Namespace, runner: Runner, resource_root: Path, cases: list[AudioCase],
            standalone: StandaloneAudioPlan | None) -> int:
    out = runner.out
    run_id = str(uuid.uuid4())
    recovery_wait = args.background_recovery or 0
    recovery_route = 'internet' if args.transport == 'webrtc' else 'local'
    for case in cases:
        if args.codec != 'default':
            case['codec'] = args.codec
        if args.isolation == 'off':
            case['transmitIsolation'] = False
    if cases:
        (out / 'scenarios.json').write_text(json.dumps(cases, indent=2) + '\n')
    if args.cleanup_only:
        measurement_ids = ()
    elif standalone:
        measurement_ids = standalone.measurement_ids
    elif args.registration_recovery:
        measurement_ids = ('local-before', 'internet-during', 'local-after')
    elif args.transport == 'mixed':
        measurement_ids = MIXED_AUDIO_MEASUREMENT_IDS
    elif recovery_wait:
        measurement_ids = (f'late-{recovery_route}', 'background-mic-off',
                           f'background-{recovery_route}-recovered', f'background-{recovery_route}-duplex')
    else:
        measurement_ids = tuple(case['id'] for case in cases)
    (out / 'configuration.json').write_text(json.dumps({'run': run_id, 'seconds': args.seconds, 'codec': args.codec,
        'isolation': args.isolation, 'buildConfiguration': args.configuration, 'input': 'bundled synthetic speech WAV', 'transport': args.transport,
        'speechPair': args.speech_pair, 'pipelineOnly': args.pipeline_only, 'realtimeOnly': args.realtime_only, 'groupOnly': args.group_only, 'codecOnly': args.codec_only, 'switchesOnly': args.switches_only,
        'switchLimitsOnly': args.switch_limits_only, 'twoSimulators': args.two_simulators,
        'backgroundRecoveryWaitSeconds': recovery_wait, 'expectedMeasurementIDs': measurement_ids,
        'output': 'system AVAudioEngine render tap'}, indent=2) + '\n')
    audio_pins = []
    leases = [SimulatorLease(runner, resource_root / name) for name in ['reusable.json', 'ephemeral.json']]
    lease = leases[int(args.ephemeral)]
    peer_lease = SimulatorLease(runner, resource_root / 'audio-peer.json', stage='peer')
    peer_reserved = False
    sources = source_manifest(ROOT)
    (out / 'source-manifest.json').write_text(json.dumps(sources, indent=2) + '\n')
    try:
        def command(name: str, argv: list[str], timeout: int = 1800) -> None:
            if not runner.run(name, argv, timeout=timeout):
                raise RuntimeError(name + ' failed; see ' + str(out))
        if peer_lease.state and not peer_lease.cleanup('peer-recovery'):
            raise RuntimeError('Could not recover the owned peer simulator')
        if args.cleanup_only:
            lease.prepare(None, None, delete_all=True)
        else:
            command('runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'], 60)
            runtimes = json.loads((out / 'runtimes.log').read_text())['runtimes']
            device_type = IPHONE_DEVICE_TYPE
            runtime = latest_runtime(runtimes, 'iOS', device_type)
            simulator = lease.prepare(runtime, device_type, reusable=not args.ephemeral)
        # Retain recovery of hosts recorded by the other (ephemeral/reusable)
        # mode without deleting the device that prepare just adopted.
        for index, old in enumerate(leases):
            if old is not lease and not old.cleanup_host(f'recovery-{index}'):
                raise RuntimeError('A previous host requires ownership review before retrying')
        if args.cleanup_only:
            return runner.exit_code
        simulators = {'simulator': simulator}
        if args.two_simulators:
            peer_lease.reserve('RideIntercom Validation Audio Peer ' + uuid.uuid4().hex[:8])
            peer_reserved = True
            peer = peer_lease.create_reserved(runtime, device_type)
            simulators['peer-simulator'] = peer
        for prefix, device_id in simulators.items():
            command(prefix + '-boot', ['xcrun', 'simctl', 'boot', device_id], 60)
            (out / (prefix + '-id.txt')).write_text(device_id + '\n')
        for prefix, device_id in simulators.items():
            command(prefix + '-ready', ['xcrun', 'simctl', 'bootstatus', device_id, '-b'], 180)
            pin = SimulatorAudioPin(device_id)
            audio_pins.append((prefix, pin))
            step = prefix + '-audio-device'
            try:
                device = pin.pin()
            except (ValueError, KeyError, subprocess.SubprocessError) as error:
                runner.record(step, [], 'failed', 1, time.monotonic(), str(error))
                raise RuntimeError(step + ' failed; see ' + str(out)) from error
            runner.record(step, [], 'passed', 0, time.monotonic(), 'Input and output pinned to ' + device)
        ios_destination = 'platform=iOS Simulator,id=' + simulator
        mac_destination = 'platform=macOS,arch=arm64'
        if args.two_simulators:
            endpoints = [('a', 'ios', 'platform=iOS Simulator,id=' + peer), ('b', 'ios', ios_destination)]
        elif recovery_wait:
            endpoints = [('a', 'ios', ios_destination), ('b', 'mac', mac_destination)]
        else:
            endpoints = [('a', 'mac', mac_destination), ('b', 'ios', ios_destination)]
        products_by_platform = build_audio_hosts(runner, endpoints, args.configuration, args.clean_build)
        ios_settings, ios_run = products_by_platform['ios']
        for prefix, device_id in simulators.items():
            step = 'microphone-permission' if prefix == 'simulator' else prefix + '-microphone-permission'
            command(step, ['xcrun', 'simctl', 'privacy', device_id, 'grant', 'microphone',
                           'com.yowamushi-inc.RideIntercom.RideIntercom'], 60)
        ios_preflight_tests = [
            'AudioE2ETests/testSpeechMatcherRejectsSilenceAndWrongSpeaker',
            'AudioE2ETests/testContinuityRejectsGapsRepeatsAndMissingSpeech',
            'AudioE2ETests/testMicroGapOverlapAndClickAreRejected',
            'AudioE2ETests/testConversationOracleRejectsMissingAcknowledgements',
            'AudioE2ETests/testSystemSessionAcceptsCallProfiles']
        if standalone:
            ios_preflight_tests.extend(standalone.preflight)
        preflight = configure_test_run(ios_run, 'preflight', 'ios', ios_settings['RIDEINTERCOM_STORAGE_NAMESPACE'],
                                       {}, identifiers=ios_preflight_tests)
        command('preflight', ['xcodebuild', 'test-without-building', '-xctestrun', str(preflight),
            '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO'], 120)
        preflight_bundle = xcode_test_result(out / 'preflight.log', preflight.parent)
        command('preflight-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(preflight_bundle), '--format', 'json'], 60)
        preflight_summary = json.loads((out / 'preflight-summary.log').read_text())
        if not xcode_tests_passed(preflight_summary) or preflight_summary['totalTestCount'] != len(ios_preflight_tests):
            raise RuntimeError('Speech oracle and real iOS session preflight must both pass')
        if not check_audio_test_selection(runner, 'preflight', preflight_bundle, ios_preflight_tests):
            raise RuntimeError('The selected iOS audio preflight tests must run')
        if 'mac' in products_by_platform:
            mac_settings, mac_run = products_by_platform['mac']
            mac_preflight_tests = [
                'AudioE2ETests/testMacFixturePacesCompletedSamples',
                'AudioE2ETests/testFixturePreservesClockGapsWithoutDelayingLaterSpeech']
            mac_preflight = configure_test_run(mac_run, 'preflight', 'mac', mac_settings['RIDEINTERCOM_STORAGE_NAMESPACE'],
                                               {}, identifiers=mac_preflight_tests)
            command('preflight-mac', ['xcodebuild', 'test-without-building', '-xctestrun', str(mac_preflight),
                '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO'], 120)
            mac_bundle = xcode_test_result(out / 'preflight-mac.log', mac_preflight.parent)
            command('preflight-mac-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(mac_bundle), '--format', 'json'], 60)
            mac_summary = json.loads((out / 'preflight-mac-summary.log').read_text())
            if not xcode_tests_passed(mac_summary) or mac_summary['totalTestCount'] != len(mac_preflight_tests):
                raise RuntimeError('Mac fixture capture clock must pass before latency measurement')
            if not check_audio_test_selection(runner, 'preflight-mac', mac_bundle, mac_preflight_tests):
                raise RuntimeError('The selected Mac audio preflight tests must run')
        transports = ['local', 'webrtc'] if args.transport == 'all' else [args.transport]
        if standalone:
            configured = configure_test_run(ios_run, 'pipeline', 'ios', ios_settings['RIDEINTERCOM_STORAGE_NAMESPACE'],
                                            {}, identifiers=standalone.tests)
            runner.run('test-pipeline', ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO'], timeout=standalone.timeout)
            pipeline_bundle = xcode_test_result(out / 'test-pipeline.log', configured.parent)
            if runner.run('summary-pipeline', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(pipeline_bundle), '--format', 'json'], timeout=60):
                summary = json.loads((out / 'summary-pipeline.log').read_text())
                passed = xcode_tests_passed(summary) and summary['totalTestCount'] == len(standalone.tests)
                result_name = 'measure-switch-limits' if args.switch_limits_only else 'accept-pipeline'
                runner.record(result_name, [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
            check_audio_test_selection(runner, 'test-pipeline', pipeline_bundle, standalone.tests)
            folder = out / 'attachments-pipeline'
            if runner.run('attachments-pipeline', ['xcrun', 'xcresulttool', 'export', 'attachments',
                '--path', str(pipeline_bundle), '--output-path', str(folder)], timeout=60):
                rows = measurements(folder, measurement_ids, 'pipeline', 'none')
                (out / 'pipeline-measurements.json').write_text(json.dumps(rows, indent=2) + '\n')
            transports = []
        measured = []
        for transport in transports:
            # A fresh group per route proves authentication separately. Reuse the
            # same app products and simulator; do not rebuild per scenario/route.
            run_id = str(uuid.uuid4())
            with socket.socket() as reservation:
                reservation.bind(('127.0.0.1', 0))
                port = reservation.getsockname()[1]
            environment = {'AUDIO_E2E_RUN': run_id, 'AUDIO_E2E_TRANSPORT': transport,
                'AUDIO_E2E_SPEECH_PAIR': args.speech_pair,
                'AUDIO_E2E_WORKER_URL': f'http://127.0.0.1:{port}', 'AUDIO_E2E_SCENARIOS': json.dumps(cases)}
            if args.matrix == 'isolation':
                environment['AUDIO_E2E_ISOLATION_NOISE'] = '1'
            if args.saved_group_start:
                environment['AUDIO_E2E_SAVED_GROUP_START'] = '1'
            if args.saved_contact_start or args.registration_recovery or args.credential_recovery or args.credential_continuation:
                environment['AUDIO_E2E_SAVED_CONTACT_START'] = '1'
            if args.registration_recovery:
                environment['AUDIO_E2E_REGISTRATION_RECOVERY'] = '1'
            if args.credential_recovery:
                environment['AUDIO_E2E_CREDENTIAL_RECOVERY'] = '1'
            if args.credential_continuation:
                environment['AUDIO_E2E_CREDENTIAL_CONTINUATION'] = '1'
            if args.unanswered_internet:
                environment['AUDIO_E2E_UNANSWERED_INTERNET'] = '1'
            if recovery_wait:
                environment.update({
                    'AUDIO_E2E_WAIT_FOR_LATE_PARTICIPANT': '1',
                    'AUDIO_E2E_BACKGROUND_MIC_OFF': '1', 'AUDIO_E2E_BACKGROUND_MUTED_WAIT_SECONDS': str(recovery_wait),
                    f'AUDIO_E2E_BACKGROUND_{recovery_route.upper()}_RECOVERY': '1',
                })
            (out / (transport + '-configuration.json')).write_text(json.dumps(environment, indent=2) + '\n')
            commands = []
            result_sources: dict[str, tuple[str, Path]] = {}
            background_roles: set[str] = set()
            for role, platform, destination in endpoints:
                settings, source = products_by_platform[platform]
                purpose = 'pair-' + role if args.two_simulators else 'pair'
                endpoint_env = environment | {'AUDIO_E2E_ROLE': role}
                if recovery_wait and platform == 'ios':
                    endpoint_env['AUDIO_E2E_BACKGROUND_AFTER_START'] = '1'
                    background_roles.add(role)
                configured = configure_test_run(
                    source, purpose, platform, settings['RIDEINTERCOM_STORAGE_NAMESPACE'], endpoint_env)
                name = transport + '-' + (platform + '-' + role if args.two_simulators else platform)
                result_sources[role] = (name, configured.parent)
                commands.append(('test-' + name, ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                    '-destination', destination, '-parallel-testing-enabled', 'NO']))
            timeout = 120 + sum(case['seconds'] + 20 for case in cases)
            if recovery_wait:
                # The quiet interval and two speech samples follow the initial speech sample.
                timeout += recovery_wait + 90 + 2 * cases[0]['seconds']
            run_pair(runner, commands, timeout,
                     wait_for_first_native_setup=not args.two_simulators)
            bundles: dict[str, Path] = {}
            for role, (name, products) in result_sources.items():
                try:
                    bundles[role] = xcode_test_result(out / ('test-' + name + '.log'), products)
                except (OSError, ValueError):
                    runner.record('result-' + name, [], 'failed', 1, time.monotonic(), 'Native Xcode result unavailable')
            if len(set(bundles.values())) != len(bundles):
                raise ValueError('Audio endpoints must report separate Xcode result bundles')
            for role, bundle in bundles.items():
                name, _ = result_sources[role]
                summary_ok = runner.run('summary-' + name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                    '--path', str(bundle), '--format', 'json'], timeout=60)
                if summary_ok:
                    summary = json.loads((out / ('summary-' + name + '.log')).read_text())
                    passed = xcode_tests_passed(summary) and summary['totalTestCount'] == 1
                    runner.record('accept-' + name, [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
                check_audio_test_selection(runner, 'test-' + name, bundle, [DUPLEX_TEST])
                folder = out / ('attachments-' + name)
                exported = runner.run('attachments-' + name, ['xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', str(bundle), '--output-path', str(folder)], timeout=60)
                if exported:
                    try:
                        measured += measurements(folder, measurement_ids, role, transport,
                                                 background=(role in background_roles) if recovery_wait else None)
                        runner.record('coverage-' + name, [], 'passed', 0, time.monotonic())
                    except (OSError, ValueError) as error:
                        runner.record('coverage-' + name, [], 'failed', 1, time.monotonic(), str(error))
        if standalone:
            runner.record('duplex-latency', [], 'not-applicable', None, time.monotonic(), 'Standalone tests use their own latency checks')
        elif recovery_wait:
            runner.record('duplex-latency', [], 'not-applicable', None, time.monotonic(),
                          'Background recovery checks restored speech; use a regular call to measure latency')
        elif args.transport != 'mixed':
            record_duplex_latency(runner, measured, cases, transports)
        (out / 'measurements.json').write_text(json.dumps(measured, indent=2) + '\n')
        after_sources = source_manifest(ROOT)
        (out / 'source-manifest-after.json').write_text(json.dumps(after_sources, indent=2) + '\n')
        unchanged = sources['head'] == after_sources['head'] and fingerprints_match(sources['files'], after_sources['files'])
        runner.record('source-stability', [], 'passed' if unchanged else 'failed', 0 if unchanged else 1,
                      time.monotonic(), 'Sources and configuration match except for advancing the shared build number')
    except (OSError, ValueError, KeyError, RuntimeError, TimeoutError, KeyboardInterrupt, subprocess.SubprocessError) as error:
        runner.record('audio-e2e', [], 'failed', 1, time.monotonic(), str(error))
    finally:
        # A second Ctrl-C must not skip teardown. SIGKILL is recovered next run.
        previous = {sig: signal.signal(sig, signal.SIG_IGN) for sig in [signal.SIGINT, signal.SIGTERM]}
        try:
            for prefix, audio_pin in reversed(audio_pins):
                try:
                    audio_pin.restore()
                    runner.record(prefix + '-audio-restore', [], 'passed', 0, time.monotonic())
                except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
                    runner.record(prefix + '-audio-restore', [], 'failed', 1, time.monotonic(),
                                  'Could not restore Simulator audio selection: ' + type(error).__name__)
            if peer_reserved:
                peer_lease.cleanup('peer-cleanup')
            if lease.acquired:
                lease.cleanup('cleanup')
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        print('Evidence: ' + str(out), flush=True)
    return runner.exit_code


if __name__ == '__main__':
    def interrupted(signum: int, frame: FrameType | None) -> None:
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(main())
