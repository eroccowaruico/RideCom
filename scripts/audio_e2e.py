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
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime
from pathlib import Path
from types import FrameType
from typing import TypedDict

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.audio_e2e_matrix import (
    MIXED_AUDIO_MEASUREMENT_IDS,
    STANDALONE_AUDIO_PLANS,
    AudioCase,
    StandaloneAudioPlan,
    scenarios,
)
from scripts.test_lifecycle import (
    SimulatorLease,
    exclusive_run,
    process_snapshot,
    simulator_resource_root,
)
from scripts.validate import (
    ROOT,
    Fingerprint,
    Runner,
    file_fingerprint,
    fingerprints_match,
    test_host_metadata,
    xcode_tests_passed,
)
from scripts.xcode_paths import (
    scheme_configuration,
    select_test_run,
    xcode_build_settings,
)


class SourceManifest(TypedDict):
    head: str
    files: dict[str, Fingerprint]


def source_manifest() -> SourceManifest:
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT).decode().split('\0')
    files = {}
    for name in sorted(set(names)):
        path = ROOT / name
        is_asset = any(part.endswith(('.xcassets', '.icon')) for part in path.parts)
        if name and (is_asset or path.suffix in {'.swift', '.py', '.pbxproj', '.xcscheme', '.wav', '.metadata', '.json', '.plist', '.resolved', '.xcstrings', '.storekit', '.entitlements', '.xcconfig', '.xctestplan', '.png', '.strings', '.stringsdict', '.xcprivacy', '.zip'}):
            files[name] = file_fingerprint(path)
    return {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'files': files}


def shared_host_audio_device(devices: Mapping[str, object], host_items: Sequence[Mapping[str, object]],
                             preferred_name: str | None = None) -> str:
    """Return the one 48 kHz host device that both captures and renders.

    The iOS Simulator opens one duplex I/O. Following separate host defaults
    (for example a USB microphone and a display speaker) leaves its native
    input at 0 Hz, so the measurement never reaches the audio path."""
    inputs: dict[str, str] = {}
    outputs: dict[str, str] = {}
    for key, destination in [('inputDevices', inputs), ('outputDevices', outputs)]:
        entries = devices[key]
        if not isinstance(entries, list):
            raise TypeError('Invalid host audio device list')
        for device in entries:
            if not isinstance(device, dict) or not isinstance(device.get('uid'), str) or not isinstance(device.get('name'), str):
                raise TypeError('Invalid host audio device')
            destination[device['uid']] = device['name']
    by_name = {item.get('_name'): item for item in host_items}
    eligible = []
    for uid, name in inputs.items():
        item = by_name.get(name)
        if outputs.get(uid) != name or item is None:
            continue
        device_input = item.get('coreaudio_device_input', 0)
        device_output = item.get('coreaudio_device_output', 0)
        if not isinstance(device_input, (int, float)) or not isinstance(device_output, (int, float)):
            raise TypeError('Invalid host audio channel count')
        if device_input >= 1 and device_output >= 1 and item.get('coreaudio_device_srate') == 48000:
            eligible.append(uid)
    if preferred_name is not None:
        named = [uid for uid in eligible if inputs[uid] == preferred_name]
        if len(named) != 1:
            raise ValueError('RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE must name one 48 kHz audio device with input and output')
        return named[0]
    for default in ('coreaudio_default_audio_input_device', 'coreaudio_default_audio_output_device'):
        preferred = [uid for uid in eligible if default in by_name[inputs[uid]]]
        if len(preferred) == 1:
            return preferred[0]
    if len(eligible) != 1:
        raise ValueError('Connect exactly one 48 kHz host audio device with input and output, '
                         f'or choose one with RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE. Found {len(eligible)} devices.')
    return eligible[0]


class SimulatorAudioPin:
    """Pin the owned Simulator's input and output to one host device for a run."""
    def __init__(self, simulator: str, run_json: Callable[[list[str]], Mapping[str, object]]) -> None:
        self.simulator = simulator
        self.run_json = run_json
        self.original = None

    @staticmethod
    def _selection(value: object) -> str:
        if value == {'systemDefault': {}}:
            return 'systemDefault'
        # devicectl encodes a pinned device as {"device": {"_0": uid}}.
        uid = value.get('device', {}).get('_0') if isinstance(value, dict) else None
        if not isinstance(uid, str) or not uid:
            raise ValueError('Unrecognized Simulator audio selection: ' + json.dumps(value))
        return uid

    def _info(self) -> Mapping[str, object]:
        return self.run_json(['xcrun', 'devicectl', 'device', 'info', 'audio', '--device', self.simulator, '--json-output', '-'])

    def _select(self, input_device: str, output_device: str) -> None:
        self.run_json(['xcrun', 'devicectl', 'device', 'settings', 'audio', '--device', self.simulator,
                       '--input-device', input_device, '--output-device', output_device, '--json-output', '-'])

    def pin(self) -> str:
        before = self._info()
        original = (self._selection(before['audioInputDevice']), self._selection(before['audioOutputDevice']))
        devices = self.run_json(['xcrun', 'devicectl', 'list', 'audioDevices', '--json-output', '-'])
        groups = self.run_json(['system_profiler', 'SPAudioDataType', '-json'])['SPAudioDataType']
        if not isinstance(groups, list):
            raise TypeError('Invalid host audio inventory')
        host: list[Mapping[str, object]] = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get('_items', []), list):
                raise TypeError('Invalid host audio group')
            for item in group.get('_items', []):
                if not isinstance(item, dict):
                    raise TypeError('Invalid host audio item')
                host.append(item)
        uid = shared_host_audio_device(devices, host, os.environ.get('RIDEINTERCOM_SIMULATOR_AUDIO_DEVICE'))
        self.original = original
        self._select(uid, uid)
        after = self._info()
        if (self._selection(after['audioInputDevice']), self._selection(after['audioOutputDevice'])) != (uid, uid):
            raise RuntimeError('Simulator audio device selection did not apply')
        return uid

    def restore(self) -> None:
        if self.original is None:
            return
        original, self.original = self.original, None
        self._select(*original)


def run_devicectl_json(args: list[str]) -> Mapping[str, object]:
    output = subprocess.run(args, capture_output=True, text=True, timeout=60, check=True).stdout
    data = json.loads(output)
    result = data.get('result', data) if args[0] == 'xcrun' else data
    if not isinstance(result, dict):
        raise TypeError('Invalid audio device command response')
    return result


def configure_test_run(source: Path, purpose: str, platform: str, namespace: str,
                       environment: dict[str, str], identifiers: Sequence[str] | None = None) -> Path:
    data = plistlib.loads(source.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if len(targets) != 1 or targets[0]['BlueprintName'] != 'RideIntercomAudioE2ETests':
        raise ValueError('Expected the dedicated audio E2E test target')
    test_host_metadata(source, namespace)
    targets[0].setdefault('EnvironmentVariables', {}).update(environment)
    limits = STANDALONE_AUDIO_PLANS['switch_limits_only'].tests
    if identifiers and tuple(identifiers) == limits:
        targets[0]['SkipTestIdentifiers'] = [
            name for name in targets[0].get('SkipTestIdentifiers', []) if name.removesuffix('()') not in limits
        ]
    targets[0]['OnlyTestIdentifiers'] = identifiers or ['AudioE2ETests/testDuplexSpeechOverNetwork']
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


def measurements(folder: Path, expected_ids: Sequence[str], role: str, transport: str) -> list[dict[str, object]]:
    rows = [json.loads(path.read_text()) for path in folder.glob('*.json') if path.name != 'manifest.json']
    rows = [row for row in rows if 'scenario' in row]
    actual = [row.get('scenario') for row in rows]
    if len(actual) != len(expected_ids) or set(actual) != set(expected_ids):
        raise ValueError('Missing or duplicate per-scenario speech measurements')
    if any(row.get('role') != role or row.get('transport') != transport for row in rows):
        raise ValueError('Speech measurements belong to a different endpoint or transport')
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
    parser.add_argument('--cleanup-only', action='store_true', help='Recover managed devices and report old running hosts without stopping unknown owners')
    parser.add_argument('--transport', choices=['local', 'webrtc', 'mixed', 'all'], default='all')
    parser.add_argument('--saved-group-start', action='store_true', help='Start Local audio from a saved group when Apple credential verification is unavailable')
    parser.add_argument('--unanswered-internet', action='store_true', help='Keep both Internet connection requests pending during saved-group Local audio')
    parser.add_argument('--matrix', choices=['smoke', 'quick', 'full', 'identity'], default='quick')
    parser.add_argument('--scenario', metavar='ID', action='append', default=[],
                        help='Run only this scenario from the network audio matrix; repeat to select multiple cases')
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
    if args.two_simulators and standalone:
        parser.error('--two-simulators requires a network audio test')
    if args.saved_group_start and (args.transport != 'local' or standalone):
        parser.error('--saved-group-start requires --transport local with the network audio test')
    if args.unanswered_internet and (not args.saved_group_start or args.matrix != 'smoke' or args.seconds > 10):
        parser.error('--unanswered-internet requires --saved-group-start --matrix smoke and 6–10 seconds')
    if args.transport == 'mixed' and (args.configuration != 'Debug' or args.matrix != 'smoke' or standalone):
        parser.error('Use --transport mixed with Debug and --matrix smoke for the Local/WebRTC recovery test')
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
    elif args.transport == 'mixed':
        measurement_ids = MIXED_AUDIO_MEASUREMENT_IDS
    else:
        measurement_ids = tuple(case['id'] for case in cases)
    (out / 'configuration.json').write_text(json.dumps({'run': run_id, 'seconds': args.seconds, 'codec': args.codec,
        'isolation': args.isolation, 'buildConfiguration': args.configuration, 'input': 'bundled synthetic speech WAV', 'transport': args.transport,
        'speechPair': args.speech_pair, 'pipelineOnly': args.pipeline_only, 'realtimeOnly': args.realtime_only, 'groupOnly': args.group_only, 'codecOnly': args.codec_only, 'switchesOnly': args.switches_only,
        'switchLimitsOnly': args.switch_limits_only, 'twoSimulators': args.two_simulators, 'expectedMeasurementIDs': measurement_ids, 'output': 'system AVAudioEngine render tap'}, indent=2) + '\n')
    audio_pins = []
    leases = [SimulatorLease(runner, resource_root / name) for name in ['reusable.json', 'ephemeral.json']]
    lease = leases[int(args.ephemeral)]
    peer_lease = SimulatorLease(runner, resource_root / 'audio-peer.json')
    peer_reserved = False
    sources = source_manifest()
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
            available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime = max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
            device_type = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'
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
            command('peer-create', ['xcrun', 'simctl', 'create', peer_lease.state['name'], device_type, runtime], 60)
            peer = (out / 'peer-create.log').read_text().strip()
            peer_lease.identify(peer)
            simulators['peer-simulator'] = peer
        for prefix, device_id in simulators.items():
            command(prefix + '-boot', ['xcrun', 'simctl', 'boot', device_id], 60)
            (out / (prefix + '-id.txt')).write_text(device_id + '\n')
        for prefix, device_id in simulators.items():
            command(prefix + '-ready', ['xcrun', 'simctl', 'bootstatus', device_id, '-b'], 180)
            pin = SimulatorAudioPin(device_id, run_devicectl_json)
            audio_pins.append((prefix, pin))
            step = prefix + '-audio-device'
            try:
                device = pin.pin()
            except (ValueError, KeyError, subprocess.SubprocessError) as error:
                runner.record(step, [], 'failed', 1, time.monotonic(), str(error))
                raise RuntimeError(step + ' failed; see ' + str(out)) from error
            runner.record(step, [], 'passed', 0, time.monotonic(), 'Input and output pinned to ' + device)
        first = ('a', 'ios', 'platform=iOS Simulator,id=' + peer) if args.two_simulators else ('a', 'mac', 'platform=macOS,arch=arm64')
        endpoints = [first, ('b', 'ios', 'platform=iOS Simulator,id=' + simulator)]
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
            '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(out / 'preflight.xcresult')], 120)
        command('preflight-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
            '--path', str(out / 'preflight.xcresult'), '--format', 'json'], 60)
        preflight_summary = json.loads((out / 'preflight-summary.log').read_text())
        if not xcode_tests_passed(preflight_summary) or preflight_summary['totalTestCount'] != len(ios_preflight_tests):
            raise RuntimeError('Speech oracle and real iOS session preflight must both pass')
        if 'mac' in products_by_platform:
            mac_settings, mac_run = products_by_platform['mac']
            mac_preflight = configure_test_run(mac_run, 'preflight', 'mac', mac_settings['RIDEINTERCOM_STORAGE_NAMESPACE'], {}, identifiers=[
                'AudioE2ETests/testMacFixturePacesCompletedSamples',
                'AudioE2ETests/testFixturePreservesClockGapsWithoutDelayingLaterSpeech'])
            command('preflight-mac', ['xcodebuild', 'test-without-building', '-xctestrun', str(mac_preflight),
                '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                '-resultBundlePath', str(out / 'preflight-mac.xcresult')], 120)
            command('preflight-mac-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(out / 'preflight-mac.xcresult'), '--format', 'json'], 60)
            mac_summary = json.loads((out / 'preflight-mac-summary.log').read_text())
            if not xcode_tests_passed(mac_summary) or mac_summary['totalTestCount'] != 2:
                raise RuntimeError('Mac fixture capture clock must pass before latency measurement')
        transports = ['local', 'webrtc'] if args.transport == 'all' else [args.transport]
        if standalone:
            configured = configure_test_run(ios_run, 'pipeline', 'ios', ios_settings['RIDEINTERCOM_STORAGE_NAMESPACE'],
                                            {}, identifiers=standalone.tests)
            runner.run('test-pipeline', ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                '-destination', 'platform=iOS Simulator,id=' + simulator, '-parallel-testing-enabled', 'NO',
                '-resultBundlePath', str(out / 'pipeline.xcresult')], timeout=standalone.timeout)
            if runner.run('summary-pipeline', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                '--path', str(out / 'pipeline.xcresult'), '--format', 'json'], timeout=60):
                summary = json.loads((out / 'summary-pipeline.log').read_text())
                passed = xcode_tests_passed(summary) and summary['totalTestCount'] == len(standalone.tests)
                result_name = 'measure-switch-limits' if args.switch_limits_only else 'accept-pipeline'
                runner.record(result_name, [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
            folder = out / 'attachments-pipeline'
            if runner.run('attachments-pipeline', ['xcrun', 'xcresulttool', 'export', 'attachments',
                '--path', str(out / 'pipeline.xcresult'), '--output-path', str(folder)], timeout=60):
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
            if args.saved_group_start:
                environment['AUDIO_E2E_SAVED_GROUP_START'] = '1'
            if args.unanswered_internet:
                environment['AUDIO_E2E_UNANSWERED_INTERNET'] = '1'
            (out / (transport + '-configuration.json')).write_text(json.dumps(environment, indent=2) + '\n')
            commands = []
            result_names = {}
            for role, platform, destination in endpoints:
                settings, source = products_by_platform[platform]
                purpose = 'pair-' + role if args.two_simulators else 'pair'
                configured = configure_test_run(source, purpose, platform, settings['RIDEINTERCOM_STORAGE_NAMESPACE'], environment | {'AUDIO_E2E_ROLE': role})
                name = transport + '-' + (platform + '-' + role if args.two_simulators else platform)
                result_names[role] = name
                commands.append(('test-' + name, ['xcodebuild', 'test-without-building', '-xctestrun', str(configured),
                    '-destination', destination, '-parallel-testing-enabled', 'NO',
                    '-resultBundlePath', str(out / (name + '.xcresult'))]))
            run_pair(runner, commands, 120 + sum(case['seconds'] + 20 for case in cases),
                     wait_for_first_native_setup=not args.two_simulators)
            for role, name in result_names.items():
                summary_ok = runner.run('summary-' + name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                    '--path', str(out / (name + '.xcresult')), '--format', 'json'], timeout=60)
                if summary_ok:
                    summary = json.loads((out / ('summary-' + name + '.log')).read_text())
                    passed = xcode_tests_passed(summary) and summary['totalTestCount'] == 1
                    runner.record('accept-' + name, [], 'passed' if passed else 'failed', 0 if passed else 1, time.monotonic())
                folder = out / ('attachments-' + name)
                exported = runner.run('attachments-' + name, ['xcrun', 'xcresulttool', 'export', 'attachments',
                    '--path', str(out / (name + '.xcresult')), '--output-path', str(folder)], timeout=60)
                if exported:
                    try:
                        measured += measurements(folder, measurement_ids, role, transport)
                        runner.record('coverage-' + name, [], 'passed', 0, time.monotonic())
                    except (OSError, ValueError) as error:
                        runner.record('coverage-' + name, [], 'failed', 1, time.monotonic(), str(error))
        if args.transport != 'mixed':
            record_duplex_latency(runner, measured, cases, transports)
        (out / 'measurements.json').write_text(json.dumps(measured, indent=2) + '\n')
        after_sources = source_manifest()
        (out / 'source-manifest-after.json').write_text(json.dumps(after_sources, indent=2) + '\n')
        unchanged = sources['head'] == after_sources['head'] and fingerprints_match(sources['files'], after_sources['files'])
        runner.record('source-stability', [], 'passed' if unchanged else 'failed', 0 if unchanged else 1,
                      time.monotonic(), 'Sources/configuration unchanged; all raw input hashes must match exactly')
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
                except (ValueError, KeyError, subprocess.SubprocessError) as error:
                    runner.record(prefix + '-audio-restore', [], 'failed', 1, time.monotonic(), str(error))
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
