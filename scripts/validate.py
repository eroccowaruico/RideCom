#!/usr/bin/env python3
"""Local validation orchestration. No deployment or access to user test data."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator, Mapping, Sequence
from contextlib import nullcontext
from datetime import datetime
from pathlib import Path
from types import FrameType
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.BuildWebRTC.webrtc_provenance import verify_imported_checksum
from scripts.crash_reports import CrashReports
from scripts.test_lifecycle import (
    ProcessIdentity,
    SimulatorLease,
    exclusive_run,
    process_snapshot,
    simulator_resource_root,
    stop_process_tree,
)
from scripts.xcode_paths import (
    scheme_configuration,
    scheme_test_plan,
    select_test_run,
    xcode_build_settings,
)

PACKAGE_PATHS = {
    'AudioCore': 'Audio/AudioCore',
    'AudioMixer': 'Audio/AudioMixer',
    'Codec': 'Audio/Codec',
    'SessionManager': 'Audio/SessionManager',
    'AudioDevice': 'Audio/AudioDevice',
    'DynamicsProcessor': 'Audio/Effectors/DynamicsProcessor',
    'PeakLimiter': 'Audio/Effectors/PeakLimiter',
    'SoundIsolation': 'Audio/Effectors/SoundIsolation',
    'VADGate': 'Audio/Effectors/VADGate',
    'RTC': 'RTC',
    'CallControl': 'CallControl',
}


class TestSummary(TypedDict, total=False):
    totalTestCount: int
    passedTests: int
    failedTests: int
    skippedTests: int
    runtimeWarnings: list[object]
    testFailures: list[object]


class TestNodeDetails(TypedDict, total=False):
    name: str
    children: list[TestNode]
    result: str
    nodeIdentifier: str


class TestNode(TestNodeDetails):
    nodeType: str


class TestTree(TypedDict):
    testNodes: list[TestNode]


class SelectionCoverage(TypedDict):
    selected: list[str]
    executed: list[str]
    missing: list[str]
    unexpected: list[str]


class Fingerprint(TypedDict, total=False):
    sha256: str | None
    build_number: int
    configuration_sha256: str


def swift_supported(output: str) -> bool:
    version = re.search(r'Swift version (\d+)\.(\d+)', output)
    return bool(version and tuple(map(int, version.groups())) >= (6, 3))


def verify_swift() -> None:
    output = subprocess.check_output(['xcrun', 'swift', '--version'], text=True, timeout=60)
    print(output)
    if not swift_supported(output):
        raise ValueError('Swift 6.3 or newer is required')


def verify_node() -> None:
    worker_engine, docs_engine = (
        json.loads((ROOT / package / 'package.json').read_text())['engines']['node']
        for package in ('server', 'tools/doc-lint')
    )
    release_pattern = r'([1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    minimum = re.fullmatch(r'\^' + release_pattern, worker_engine)
    if minimum is None or worker_engine != docs_engine:
        raise ValueError('Worker and documentation tooling must declare the same Node.js range as ^major.minor.patch')

    required = tuple(map(int, minimum.groups()))
    release = subprocess.check_output(['node', '--version'], text=True, timeout=20).strip()
    version = re.fullmatch('v' + release_pattern, release)
    if version is None or version[1] != minimum[1] or tuple(map(int, version.groups())) < required:
        raise ValueError(f'Node.js {worker_engine[1:]} or newer within major {minimum[1]} (stable release) is required')
    print(release)


def verify_artifact() -> None:
    artifact = ROOT / 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'
    verify_imported_checksum(artifact)
    with tempfile.TemporaryDirectory(prefix='rideintercom-artifact-') as folder:
        subprocess.run(['ditto', '-x', '-k', str(artifact), folder], check=True, timeout=60)
        subprocess.run(['bash', str(ROOT / 'scripts/BuildWebRTC/verify-webrtc-xcframework.sh'),
                        str(Path(folder) / 'WebRTC.xcframework')], check=True, timeout=60)


def tests_passed(text: str) -> bool:
    """Require an actual nonempty test run; compilation alone is not success."""
    if re.search(r'\bskipped[=: ]+[1-9]|\b[1-9]\d* tests? skipped|Test .* skipped', text, re.IGNORECASE):
        return False
    swift = re.search(r'Test run with (\d+) tests? .*passed', text)
    if swift:
        return int(swift[1]) > 0 and not re.search(r'Test .* failed', text)
    python = re.search(r'Ran (\d+) tests?\b', text)
    if python:
        return int(python[1]) > 0 and re.search(r'^OK\s*$', text, re.MULTILINE) is not None
    node = dict(re.findall(r'^[#ℹ]\s+(tests|pass|fail|skipped|cancelled|todo)\s+(\d+)', text, re.MULTILINE))
    return (int(node.get('tests', 0)) > 0 and node.get('pass') == node.get('tests')
            and all(int(node.get(key, 0)) == 0 for key in ['fail', 'skipped', 'cancelled', 'todo']))


# The iPhone stage runs the App tests and then every UI test one at a time on one Simulator;
# 61 UI tests alone took 4307 s (2026-11-17), so the general stage limit cannot hold it.
IOS_TESTS_SECONDS = 7200


def ios_tests_timeout(environment: Mapping[str, str]) -> int | None:
    """An explicit VALIDATION_TIMEOUT_SECONDS still limits every stage, this one included."""
    return None if environment.get('VALIDATION_TIMEOUT_SECONDS') else IOS_TESTS_SECONDS


def xcode_tests_passed(summary: TestSummary) -> bool:
    count = summary.get('totalTestCount', 0)
    return (count > 0 and summary.get('passedTests') == count
            and summary.get('failedTests', 0) == 0 and summary.get('skippedTests', 0) == 0
            and not summary.get('runtimeWarnings') and not summary.get('testFailures'))


def includes_test(selector: str, identifier: str) -> bool:
    requested = selector.split('/')
    actual = identifier.split('/')
    if len(requested) == len(actual) and len(requested) >= 3:
        if '(' not in requested[-1]:
            actual[-1] = actual[-1].split('(', 1)[0]
        else:
            requested[-1] = requested[-1].removesuffix('()')
            actual[-1] = actual[-1].removesuffix('()')
    return requested == actual[:len(requested)]


def test_selection_coverage(result: TestTree, selectors: list[str]) -> SelectionCoverage:
    def cases(nodes: list[TestNode], target: str | None = None) -> Iterator[str]:
        for node in nodes:
            kind = node['nodeType']
            if kind in ('Unit test bundle', 'UI test bundle'):
                yield from cases(node['children'], node['name'])
            elif kind == 'Test Case' and target and node.get('result') != 'Skipped':
                yield target + '/' + node['nodeIdentifier']
            else:
                yield from cases(node.get('children', []), target)

    executed = sorted(set(cases(result['testNodes'])))
    matched_selectors = set()
    unexpected = []
    for test in executed:
        matching = {selector for selector in selectors if includes_test(selector, test)}
        if matching:
            matched_selectors.update(matching)
        else:
            unexpected.append(test)
    return {
        'selected': selectors,
        'executed': executed,
        'missing': [selector for selector in selectors if selector not in matched_selectors],
        'unexpected': unexpected,
    }


def test_host_metadata(test_run: str | os.PathLike[str] | None, expected_namespace: str,
                       expected_product: str = 'RideIntercom.app') -> dict[str, str | list[str]]:
    """Validate the product actually referenced by Xcode, before it can start."""
    if not (expected_namespace.startswith('RideIntercom.Validation.')
            and len(expected_namespace) > len('RideIntercom.Validation.')):
        raise ValueError('An isolated test namespace is required')
    if Path(expected_product).name != expected_product or Path(expected_product).suffix != '.app':
        raise ValueError('Expected an App product name')
    if test_run is None:
        raise ValueError('Missing generated xctestrun')
    test_run = Path(test_run)
    products = test_run.parent.resolve()
    if not test_run.resolve().is_relative_to(products):
        raise ValueError('Test run must remain inside its build products')
    data = plistlib.loads(test_run.read_bytes())
    targets = [target for config in data['TestConfigurations'] for target in config['TestTargets']]
    if not targets:
        raise ValueError('Missing test targets')
    hosts = set()
    for target in targets:
        resolved = {}
        for key in ('TestHostPath', 'UITargetAppPath'):
            if key not in target:
                continue
            host = Path(target[key])
            if host.parts[:1] == ('__TESTROOT__',):
                host = products.joinpath(*host.parts[1:])
            elif not host.is_absolute():
                raise ValueError('Test host must use __TESTROOT__ or an absolute path')
            path = host.resolve()
            if not path.is_relative_to(products) or path.suffix != '.app':
                raise ValueError('Test host must be an app inside its build products')
            resolved[key] = path
        app = resolved.get('UITargetAppPath', resolved.get('TestHostPath'))
        if app is None or app.name != expected_product:
            raise ValueError('Missing expected App test host')
        info = app / ('Contents/Info.plist' if (app / 'Contents').is_dir() else 'Info.plist')
        if not info.resolve().is_relative_to(products):
            raise ValueError('Test host Info must remain inside its build products')
        metadata = plistlib.loads(info.read_bytes())
        if metadata.get('StorageNamespace') != expected_namespace:
            raise ValueError('Generated host storage namespace does not match this test run')
        if 'DevelopmentInternetConnection' in metadata:
            raise ValueError('Generated test host contains development connection settings')
        hosts.add(str(info))
    return {'testRun': str(test_run), 'namespace': expected_namespace, 'hostInfoPaths': sorted(hosts)}


class StageDetails(TypedDict, total=False):
    command: list[str]
    exit_code: int | None
    duration_seconds: float
    reason: str


class StageResult(StageDetails):
    status: str


class Runner:
    def __init__(self, out: str | os.PathLike[str], timeout: float = 1800,
                 crash_reports: CrashReports | None = None) -> None:
        self.out = Path(out).resolve()
        self.out.mkdir(parents=True, exist_ok=True)
        # Exclusive creation protects old evidence, including interrupted runs.
        with (self.out / 'results.tsv').open('x') as f:
            f.write('stage\tstatus\texit_code\tduration_seconds\n')
        self.results: dict[str, StageResult] = {}
        self.timeout = timeout
        self.crash_reports = crash_reports

    @property
    def exit_code(self) -> int:
        return int(any(r['status'] not in ('passed', 'not-applicable') for r in self.results.values()))

    def record(self, name: str, command: list[str], status: str, code: int | None,
               started: float, reason: str = '') -> bool:
        result: StageResult = {'command': command, 'status': status, 'exit_code': code,
                               'duration_seconds': round(time.monotonic() - started, 3), 'reason': reason}
        self.results[name] = result
        with (self.out / 'results.tsv').open('a') as f:
            f.write(f'{name}\t{status}\t{code}\t{result["duration_seconds"]}\n')
        (self.out / 'results.json').write_text(json.dumps(self.results, indent=2) + '\n')
        print(f'{name}: {status}' + (f' ({reason})' if reason else ''), flush=True)
        return status == 'passed'

    @staticmethod
    def stop(process: subprocess.Popen[bytes], original: ProcessIdentity | None) -> str:
        try:
            if original is None and process.returncode is None:
                original = process_snapshot().get(process.pid)
            stop_process_tree(process, original)
            return ''
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            # A cleanup failure must not erase the original timeout/interruption.
            # Popen still owns its unreaped direct child; do not guess other PIDs.
            try:
                process.kill()
                process.wait(timeout=2)
            except (OSError, subprocess.SubprocessError) as fallback:
                return f'process cleanup failed: {error}; direct child cleanup failed: {fallback}'
            return f'process cleanup failed: {error}'

    def wait_for_stage(self, process: subprocess.Popen[bytes], timeout: float) -> int:
        if self.crash_reports is None:
            return process.wait(timeout=timeout)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            try:
                return process.wait(timeout=max(0, min(remaining, self.crash_reports.interval_seconds)))
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise
                self.crash_reports.sample()

    def run(self, name: str, command: list[str], needs: Sequence[str] = (), tests: bool = False,
            timeout: float | None = None, reason: str = '', env: Mapping[str, str] | None = None) -> bool:
        started = time.monotonic()
        if name in self.results:
            raise ValueError(f'Duplicate stage: {name}')
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            return self.record(name, command, 'blocked', None, started, 'requires ' + ', '.join(blocked))
        print(f'Running {name}', flush=True)
        path = self.out / f'{name}.log'
        status, code = 'failed', 1
        process = None
        try:
            observation = self.crash_reports.stage(name) if self.crash_reports else nullcontext()
            with observation, path.open('w') as output:
                process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                           start_new_session=True, env=env)
                original = None
                try:
                    original = process_snapshot().get(process.pid)
                    code = self.wait_for_stage(process, timeout if timeout is not None else self.timeout)
                    status = 'passed' if code == 0 else 'failed'
                except subprocess.TimeoutExpired:
                    cleanup = self.stop(process, original)
                    status, code, reason = 'timeout', 124, 'command exceeded deadline'
                    if cleanup:
                        reason += '; ' + cleanup
                except KeyboardInterrupt:
                    cleanup = self.stop(process, original)
                    self.record(name, command, 'interrupted', 130, started, cleanup)
                    raise
                except (OSError, ValueError, subprocess.SubprocessError):
                    self.stop(process, original)
                    raise
        except OSError as error:
            path.write_text(str(error) + '\n')
            status, code, reason = 'blocked', 127, str(error)
        if status == 'passed' and tests and not tests_passed(path.read_text(errors='replace')):
            status, code, reason = 'failed', 1, 'missing, empty, failed, or skipped test results'
        passed = self.record(name, command, status, code, started, reason)
        if not passed:
            print('\n'.join(path.read_text(errors='replace').splitlines()[-12:]), flush=True)
        return passed

    def check_test_host(self, name: str, test_run: str | os.PathLike[str] | None, namespace: str,
                        needs: Sequence[str] = (), expected_product: str = 'RideIntercom.app') -> bool:
        started = time.monotonic()
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            return self.record(name, [], 'blocked', None, started, 'requires ' + ', '.join(blocked))
        try:
            metadata = test_host_metadata(test_run, namespace, expected_product=expected_product)
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            return self.record(name, [], 'failed', 1, started, str(error))
        (self.out / (name + '.json')).write_text(json.dumps(metadata, indent=2) + '\n')
        return self.record(name, [], 'passed', 0, started, 'Generated host isolation verified before launch')

    def xcode(self, name: str, destination: str, only: str | Sequence[str] | None = None,
              needs: Sequence[str] = (), skip: str | Sequence[str] | None = None, reuse_build: str | None = None,
              scheme: str = 'RideIntercom', timeout: float | None = None, verify_selection: bool = False) -> None:
        bundle = self.out / f'{name}.xcresult'
        settings_stage = name + '-build-settings'
        started = time.monotonic()
        settings, test_run, configuration, namespace, plan_name = None, None, '', '', None
        blocked = [n for n in needs if self.results.get(n, {}).get('status') != 'passed']
        if blocked:
            self.record(settings_stage, [], 'blocked', None, started, 'requires ' + ', '.join(blocked))
        else:
            try:
                configuration = scheme_configuration(ROOT, scheme)
                plan_name = scheme_test_plan(ROOT, scheme)
                settings = xcode_build_settings(ROOT, scheme, destination, configuration)
                if reuse_build:
                    previous = json.loads((self.out / f'{reuse_build}-build-settings.json').read_text())
                    if settings != previous:
                        raise ValueError('The reused build does not match this scheme configuration and destination')
                (self.out / f'{name}-build-settings.json').write_text(json.dumps(settings, indent=2) + '\n')
                namespace = settings['RIDEINTERCOM_STORAGE_NAMESPACE']
                self.record(settings_stage, [], 'passed', 0, started, 'Resolved standard Xcode product paths')
            except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
                self.record(settings_stage, [], 'failed', 1, started, str(error))
        needs = [settings_stage]
        if not reuse_build:
            command = ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj', '-scheme', scheme,
                       '-destination', destination, '-configuration', configuration]
            if plan_name:
                command += ['-testPlan', plan_name]
            self.run(name + '-build', command, needs=needs)
            needs = [name + '-build']
        if settings is not None:
            test_run = select_test_run(settings, scheme)
        preflight = name + '-host-preflight'
        self.check_test_host(preflight, test_run, namespace, needs=needs,
                             expected_product=settings['FULL_PRODUCT_NAME'] if settings else 'RideIntercom.app')
        if plan_name:
            # StoreKit activation belongs to the shared plan and is not carried
            # by the generated xctestrun. Keep its host preflight above, then use
            # the same project/scheme/plan entry as Xcode Test.
            command = ['xcodebuild', 'test-without-building', '-project', 'RideIntercom.xcodeproj',
                       '-scheme', scheme, '-testPlan', plan_name, '-configuration', configuration]
        else:
            command = ['xcodebuild', 'test-without-building', '-xctestrun', str(test_run or '')]
        command += ['-destination', destination, '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(bundle)]
        selectors = [only] if isinstance(only, str) else list(only or [])
        for identifier in selectors:
            command.append(f'-only-testing:{identifier}')
        skips = [skip] if isinstance(skip, str) else list(skip or [])
        if skips:
            # A command-line skip replaces the scheme's skipped tests in the xctestrun,
            # so restate them; otherwise scheme-excluded suites would run here.
            for identifier in (xctestrun_skips(test_run) if test_run and not plan_name else []) + skips:
                command.append(f'-skip-testing:{identifier}')
        test_env = None
        if settings and settings['PLATFORM_NAME'] == 'macosx':
            test_env = os.environ.copy()
            test_env.setdefault('TEST_RUNNER_PATH', test_env.get('PATH', os.defpath) + ':__CURRENT_VALUE__')
        self.run(name, command, needs=[preflight], timeout=timeout, env=test_env)
        summary_name = name + '-summary'
        self.run(summary_name, ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary', '--path', str(bundle)], needs=[name], timeout=60)
        started = time.monotonic()
        try:
            summary = json.loads((self.out / f'{summary_name}.log').read_text())
            passed = self.results[summary_name]['status'] == 'passed' and xcode_tests_passed(summary)
        except (OSError, ValueError):
            passed = False
        self.record(name + '-acceptance', [], 'passed' if passed else 'failed', 0 if passed else 1,
                    started, 'requires nonzero tests, no failures/skips/runtime warnings, and a readable xcresult')
        if verify_selection:
            self.check_test_selection(name, bundle, selectors)

    def check_test_selection(self, name: str, bundle: Path, selectors: list[str]) -> None:
        listing = name + '-tests'
        self.run(listing, ['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                           '--path', str(bundle), '--compact'], needs=[name], timeout=60)
        started = time.monotonic()
        stage = name + '-selection'
        try:
            result = json.loads((self.out / f'{listing}.log').read_text())
            coverage = test_selection_coverage(result, selectors)
            (self.out / f'{stage}.json').write_text(json.dumps(coverage, indent=2) + '\n')
            passed = self.results[listing]['status'] == 'passed' and not (coverage['missing'] or coverage['unexpected'])
            reason = 'Each selector ran and all executed tests matched the selection' if passed else (
                f"Missing selectors: {coverage['missing']}; unexpected tests: {coverage['unexpected']}")
            self.record(stage, [], 'passed' if passed else 'failed', 0 if passed else 1, started, reason)
        except (OSError, ValueError, KeyError, TypeError) as error:
            self.record(stage, [], 'failed', 1, started, 'Cannot verify selected tests: ' + str(error))


def file_fingerprint(path: Path) -> Fingerprint:
    if not path.is_file():
        return {'sha256': None}
    data = path.read_bytes()
    result: Fingerprint = {'sha256': hashlib.sha256(data).hexdigest()}
    if path.name == 'project.pbxproj' and path.parent.name == 'RideIntercom.xcodeproj':
        pattern = rb'(CURRENT_PROJECT_VERSION\s*=\s*)([1-9][0-9]*)(\s*;)'
        numbers = re.findall(pattern, data)
        # Keep the raw hash as evidence. Only the common positive build number
        # may advance; every other project byte remains part of the comparison.
        if numbers and len({row[1] for row in numbers}) == 1:
            result['build_number'] = int(numbers[0][1])
            normalized = re.sub(pattern, rb'\1<BUILD_NUMBER>\3', data)
            result['configuration_sha256'] = hashlib.sha256(normalized).hexdigest()
    return result


def fingerprints_match(before: dict[str, Fingerprint], after: dict[str, Fingerprint]) -> bool:
    if before.keys() != after.keys():
        return False
    for name, original in before.items():
        current = after[name]
        if original == current:
            continue
        if (name != 'RideIntercom.xcodeproj/project.pbxproj'
                or not isinstance(original, dict) or not isinstance(current, dict)
                or set(original) != {'sha256', 'build_number', 'configuration_sha256'}
                or original.keys() != current.keys()
                or original['configuration_sha256'] != current['configuration_sha256']
                or current['build_number'] < original['build_number']):
            return False
    return True


def snapshot(out: Path) -> None:
    # Hash file contents without copying potential credentials to the report.
    files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
    hashes = {}
    for name in sorted(set(filter(None, files))):
        path = ROOT / name
        hashes[name] = file_fingerprint(path)
    (out / 'inputs.json').write_text(json.dumps(hashes, ensure_ascii=False, indent=2) + '\n')


# Tests of the regular-width layout. They skip themselves below 600x500 points.
IPAD_ONLY_TESTS = ['RideIntercomUITests/DesignSystemCallUITests/testRegularWidthUsesSeparateCallColumns']
IPAD_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB'
WATCH_DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-12-46mm'
RECOVERY_TEST = 'RideIntercomUITests/RideIntercomUITests/testCorruptGroupStoreRecovery'
SIMULATOR_AUDIO_TESTS = [
    'RideIntercomUITests/RideIntercomUITests/testPhoneAudioCheckRecordsAndPlaysFromSettings',
    'RideIntercomUITests/BackgroundCallLifecycleUITests',
    'RideIntercomUITests/DesignSystemDiagnosticsUITests/testTXShowsLiveIsolationWithEffectsClosed',
]


def ios_test_selection(selectors: Sequence[str]) -> tuple[list[str], list[str], list[str]]:
    device_specific = [RECOVERY_TEST, *IPAD_ONLY_TESTS]
    iphone = [selector for selector in selectors
              if not any(includes_test(test, selector) for test in device_specific)]
    selected_special = [test for test in device_specific
                        if any(includes_test(selector, test) for selector in selectors)]
    return (iphone, [test for test in selected_special if test == RECOVERY_TEST],
            [test for test in selected_special if test in IPAD_ONLY_TESTS])


def xctestrun_skips(path: str | os.PathLike[str]) -> list[str]:
    """Scheme-skipped tests recorded in a generated xctestrun, as -skip-testing identifiers."""
    try:
        data = plistlib.loads(Path(path).read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        return []
    return [f'{target["BlueprintName"]}/{identifier}'
            for configuration in data.get('TestConfigurations', [])
            for target in configuration.get('TestTargets', []) if target.get('BlueprintName')
            for identifier in target.get('SkipTestIdentifiers', [])]


def boot_simulator(runner: Runner, sim: str, stage: str, timeout: int = 180) -> None:
    id_filename = 'simulator-id.txt' if stage == 'simulator' else f'{stage}-simulator-id.txt'
    (runner.out / id_filename).write_text(sim + '\n')
    if runner.crash_reports is not None:
        runner.crash_reports.add_simulator(sim)
    runner.run(f'{stage}-boot', ['xcrun', 'simctl', 'boot', sim], timeout=120)
    runner.run(f'{stage}-ready', ['xcrun', 'simctl', 'bootstatus', sim, '-b'],
               needs=[f'{stage}-boot'], timeout=timeout)


def run_iphone_tests(runner: Runner, runtime: str, iphone_tests: list[str],
                     recovery_tests: list[str], focused: bool) -> None:
    lease = SimulatorLease(runner, simulator_resource_root() / 'reusable.json')
    audio_pin = None
    try:
        device = os.environ.get('SIMULATOR_DEVICE_TYPE', 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
        sim = lease.prepare(runtime, device)
        if not sim:
            return
        boot_simulator(runner, sim, 'simulator')
        runner.run('simulator-appearance', ['xcrun', 'simctl', 'ui', sim, 'appearance',
                    os.environ.get('SIMULATOR_APPEARANCE', 'dark')], needs=['simulator-ready'], timeout=30)
        needs = ['simulator-ready', 'simulator-appearance', 'webrtc-artifact']
        if not focused or any(includes_test(selector, audio) or includes_test(audio, selector)
                              for selector in iphone_tests for audio in SIMULATOR_AUDIO_TESTS):
            # Split host defaults can leave the Simulator microphone at 0 Hz.
            from scripts.audio_e2e import SimulatorAudioPin, run_devicectl_json
            audio_pin = SimulatorAudioPin(sim, run_devicectl_json)
            try:
                audio_device = audio_pin.pin()
                runner.record('simulator-audio-device', [], 'passed', 0, time.monotonic(), 'Input and output pinned to ' + audio_device)
            except (ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
                runner.record('simulator-audio-device', [], 'failed', 1, time.monotonic(), str(error))
            if focused:
                needs.append('simulator-audio-device')
        destination = 'platform=iOS Simulator,id=' + sim
        if not focused or iphone_tests:
            full_ui_suite = not focused or 'RideIntercomUITests' in iphone_tests
            runner.xcode('ios-tests', destination, only=iphone_tests, needs=needs,
                         skip=[RECOVERY_TEST, *IPAD_ONLY_TESTS], verify_selection=focused,
                         timeout=ios_tests_timeout(os.environ) if full_ui_suite else None)
            needs = [*needs, 'ios-tests-acceptance']
            if focused:
                needs.append('ios-tests-selection')
        if recovery_tests:
            runner.xcode('ios-recovery', destination, only=recovery_tests, needs=needs,
                         reuse_build='ios-tests' if not focused or iphone_tests else None,
                         verify_selection=focused)
    finally:
        started = time.monotonic()
        try:
            if audio_pin is not None:
                audio_pin.restore()
        except (OSError, RuntimeError, ValueError, TypeError, subprocess.SubprocessError) as error:
            runner.record('simulator-audio-restore', [], 'failed', 1, started,
                          'Could not restore Simulator audio selection: ' + type(error).__name__)
        finally:
            if lease.acquired:
                lease.cleanup('simulator-final')


def run_ios_tests(runner: Runner, mode: str, selectors: list[str] | None) -> None:
    focused = bool(selectors)
    if focused:
        iphone_tests, recovery_tests, ipad_tests = ios_test_selection(selectors)
    else:
        iphone_tests = ['RideIntercomUITests'] if mode == 'ios-ui' else []
        recovery_tests, ipad_tests = [RECOVERY_TEST], IPAD_ONLY_TESTS
    try:
        with exclusive_run(simulator_resource_root() / 'run.lock'):
            if not runner.run('simulator-runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'],
                              needs=['swift-toolchain'], timeout=60):
                return
            runtimes = json.loads((runner.out / 'simulator-runtimes.log').read_text())['runtimes']
            available = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime = os.environ.get('SIMULATOR_RUNTIME') or max(available, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
            needs = ['webrtc-artifact']
            build_stage = None
            if not focused or iphone_tests or recovery_tests:
                run_iphone_tests(runner, runtime, iphone_tests, recovery_tests, focused)
                if not focused or iphone_tests:
                    build_stage = 'ios-tests'
                    needs.append('ios-tests-acceptance')
                    if focused:
                        needs.append('ios-tests-selection')
            if ipad_tests:
                lease = SimulatorLease(runner, simulator_resource_root() / 'reusable-ipad.json', stage='ipad')
                try:
                    if any(runner.results.get(stage, {}).get('status') != 'passed' for stage in needs):
                        raise RuntimeError('iPad tests require their prerequisites to pass first')
                    sim = lease.prepare(runtime, os.environ.get('SIMULATOR_IPAD_DEVICE_TYPE', IPAD_DEVICE_TYPE))
                    if sim:
                        boot_simulator(runner, sim, 'ipad')
                        runner.xcode('ipad-tests', 'platform=iOS Simulator,id=' + sim, only=ipad_tests,
                                     needs=[*needs, 'ipad-ready'], reuse_build=build_stage, verify_selection=focused)
                finally:
                    if lease.acquired:
                        lease.cleanup('ipad-final')
            if not focused:
                lease = SimulatorLease(runner, simulator_resource_root() / 'reusable-watch.json', stage='watch')
                try:
                    if runner.results.get('ios-tests-acceptance', {}).get('status') != 'passed':
                        raise RuntimeError('Watch tests require the iPhone run to pass first')
                    watch_runtimes = [r for r in runtimes if r['isAvailable'] and r['name'].startswith('watchOS')]
                    runtime = max(watch_runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))['identifier']
                    sim = lease.prepare(runtime, os.environ.get('SIMULATOR_WATCH_DEVICE_TYPE', WATCH_DEVICE_TYPE))
                    if sim:
                        boot_simulator(runner, sim, 'watch', timeout=300)
                        runner.xcode('watch-tests', 'platform=watchOS Simulator,id=' + sim,
                                     only=['RideIntercomWatchUITests'],
                                     needs=['watch-ready', 'ios-tests-acceptance'], scheme='RideIntercomWatch')
                finally:
                    if lease.acquired:
                        lease.cleanup('watch-final')
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        runner.record('simulator-availability', [], 'blocked', None, time.monotonic(), str(error))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', nargs='?', default='all', choices=['all', 'headless', 'packages', 'worker', 'pair', 'macos', 'ios', 'ios-ui', 'scripts'])
    parser.add_argument('--clean', action='store_true', help='Run standard swift package clean before package tests, using each package .build directory')
    parser.add_argument('--thread-sanitizer', action='store_true', help='Run supported Swift package tests under Thread Sanitizer')
    parser.add_argument('--package', action='append', default=[], choices=PACKAGE_PATHS,
                        help='Run only these packages in packages mode; repeat to add packages')
    parser.add_argument('--only-testing', action='append', default=[], metavar='TARGET[/SUITE/...[/METHOD]]',
                        help='Run selected Xcode tests in macos, ios or ios-ui; repeat to add selections')
    args = parser.parse_args()
    if args.package and args.mode != 'packages':
        parser.error('--package requires packages mode')
    targets = {
        'macos': {'RideIntercomTests'},
        'ios': {'RideIntercomTests', 'RideIntercomUITests'},
        'ios-ui': {'RideIntercomUITests'},
    }
    if args.only_testing and args.mode not in targets:
        parser.error('--only-testing requires macos, ios or ios-ui')
    for selector in args.only_testing:
        parts = selector.split('/')
        if not all(re.fullmatch(r'[^\s/]+', part) for part in parts) or parts[0] not in targets[args.mode]:
            parser.error(f'Invalid test selector for {args.mode}: {selector!r}')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    os.environ['NO_COLOR'] = '1'
    os.environ['CI'] = '1'  # Noninteractive tool output; this still runs locally.
    out = os.environ.get('VALIDATION_DIR', ROOT / '.validation' / datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    runner = Runner(out, timeout=float(os.environ.get('VALIDATION_TIMEOUT_SECONDS', '1800')))
    runner.crash_reports = CrashReports(runner.out / 'crash-reports.json')
    runner.crash_reports.sample()
    snapshot(runner.out)
    runner.run('environment', ['sh', '-c', 'git rev-parse HEAD; git status --short; sw_vers; xcodebuild -version; swift --version; node --version; npm --version'], timeout=60)
    python = sys.executable
    runner.run('development-setup', [python, 'scripts/check_development_setup.py'])
    runner.run('node-toolchain', [python, '-c', 'from scripts.validate import verify_node; verify_node()'], timeout=30)
    runner.run('documentation', [python, 'scripts/check_documentation.py'], needs=['node-toolchain'])
    runner.run('wording-review', [python, 'scripts/review_wording.py'])
    runner.run('string-catalogs', [python, 'scripts/check_string_catalogs.py'])
    mode = args.mode
    swift_needed = mode in ('all', 'headless', 'packages', 'pair', 'macos', 'ios', 'ios-ui')
    if swift_needed:
        runner.run('swift-toolchain', [python, '-c', 'from scripts.validate import verify_swift; verify_swift()'], timeout=65)
        if mode != 'packages' or not args.package or 'RTC' in args.package:
            runner.run('webrtc-artifact', [python, '-c', 'from scripts.validate import verify_artifact; verify_artifact()'], timeout=180)
    if mode in ('all', 'headless', 'packages'):
        for name, relative_path in PACKAGE_PATHS.items():
            if args.package and name not in args.package:
                continue
            package_path = 'RideIntercom/packages/' + relative_path
            command = ['swift', 'test', '--package-path', package_path]
            needs = ['swift-toolchain'] + (['webrtc-artifact'] if name == 'RTC' else [])
            if args.clean:
                clean = 'package-' + name + '-clean'
                runner.run(clean, ['swift', 'package', '--package-path', package_path, 'clean'], needs=needs)
                needs += [clean]
            if args.thread_sanitizer:
                command += ['--sanitize=thread']
            if name == 'RTC':
                # Swift Testing otherwise runs suites concurrently even when
                # SwiftPM's default says "no parallel". Keep accelerated ten-minute
                # CPU stress and deliberate actor stalls off the real-time gates.
                command += ['--no-parallel', '--skip', 'WorkerPairTests']  # Pair has its own server stage.
            runner.run('package-' + name, command, needs=needs, tests=True)
    if mode in ('all', 'headless', 'worker', 'pair'):
        runner.run('worker-install', ['npm', '--prefix', 'server', 'ci'], needs=['node-toolchain'])
        runner.run('worker-types', ['npm', '--prefix', 'server', 'run', 'type-check'], needs=['worker-install'])
        runner.run('worker-test', ['npm', '--prefix', 'server', 'test'], needs=['worker-install'], tests=True)
    if mode in ('all', 'headless', 'worker', 'pair', 'scripts'):
        lint_args = ['--web'] if mode in ('worker', 'pair') else []
        runner.run('language-lint', [python, 'scripts/lint.py', '--base', 'HEAD^', *lint_args],
                   needs=['worker-install'] if mode != 'scripts' else [])
    if mode in ('all', 'headless', 'pair'):
        pair_needs = ['worker-install', 'swift-toolchain', 'webrtc-artifact']
        if args.clean:
            clean = 'package-RTC-clean'
            if clean not in runner.results:
                runner.run(clean, ['swift', 'package', '--package-path', 'RideIntercom/packages/RTC', 'clean'],
                           needs=['swift-toolchain', 'webrtc-artifact'])
            pair_needs += [clean]
        if args.thread_sanitizer:
            os.environ['RIDEINTERCOM_PAIR_SANITIZER'] = 'thread'
        runner.run('swift-worker-pair', ['npm', '--prefix', 'server', 'run', 'test:pair'], needs=pair_needs, tests=True)
    if mode in ('all', 'headless', 'scripts'):
        runner.run('script-tests', [python, '-m', 'unittest', 'discover', '-s', 'scripts/tests'], tests=True)
        runner.run('cloudflare-scripts', ['node', '--test', 'scripts/Cloudflare/estimate-cost.test.mjs'], needs=['node-toolchain'], tests=True)
    if mode in ('all', 'macos'):
        try:
            with exclusive_run(simulator_resource_root() / 'run.lock'):
                runner.xcode('macos-tests', 'platform=macOS,arch=arm64',
                             only=args.only_testing or 'RideIntercomTests',
                             needs=['swift-toolchain', 'webrtc-artifact'], verify_selection=bool(args.only_testing))
        except BlockingIOError:
            runner.record('macos-tests', [], 'blocked', None, time.monotonic(), 'Another managed App or audio test run is active')
    if mode in ('all', 'ios', 'ios-ui'):
        run_ios_tests(runner, mode, args.only_testing)
    # A concurrent edit invalidates evidence rather than silently passing.
    before = (runner.out / 'inputs.json').read_text()
    snapshot(runner.out)
    after = (runner.out / 'inputs.json').read_text()
    (runner.out / 'inputs-before.json').write_text(before)
    runner.record('unchanged-inputs', [], 'passed' if fingerprints_match(json.loads(before), json.loads(after)) else 'failed', 0 if fingerprints_match(json.loads(before), json.loads(after)) else 1,
                  time.monotonic(), 'source/configuration fingerprints must match except for advancing the shared build number')
    runner.crash_reports.sample()
    print(f'Crash reports: {runner.out / "crash-reports.json"}')
    print(f'Results: {runner.out / "results.tsv"}')
    return runner.exit_code


if __name__ == '__main__':
    def interrupted(signum: int, frame: FrameType | None) -> None:
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
