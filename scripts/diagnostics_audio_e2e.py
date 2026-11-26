#!/usr/bin/env python3
"""Observe RX diagnostics through a received speech, silence, and speech sequence."""
from __future__ import annotations

import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import ExitStack
from pathlib import Path
from types import FrameType

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.audio_e2e import (
    DUPLEX_TEST,
    SimulatorAudioPin,
    build_audio_host,
    configure_test_run,
    scenarios,
)
from scripts.test_lifecycle import (
    IPHONE_DEVICE_TYPE,
    ProcessIdentity,
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
    xcode_tests_passed,
)
from scripts.xcode_paths import (
    scheme_configuration,
    select_test_run,
    xcode_build_settings,
    xcode_test_result,
)

APP = 'com.yowamushi-inc.RideIntercom.RideIntercom'
RECEIVER_TEST = (
    'RideIntercomUITests/BackgroundCallLifecycleUITests/testStartInvitedTrialGroupMutedInAdvanced'
)
SENDER_TEST = 'RideIntercomAudioE2ETests/' + DUPLEX_TEST
RECEIVER_OBSERVATION = 'background-call-advanced-open.json'
OUTPUT_LINE = (
    r'(?m)^AUDIO_E2E_DIAGNOSTICS_{phase} (\d+\.\d+) '
    r'{state}, Last audible PCM · (\d+)s ago / Last render · (\d+)s ago\s*$'
)


def run(runner: Runner, name: str, args: list[str], timeout: int = 60) -> None:
    if not runner.run(name, args, timeout=timeout):
        raise RuntimeError(f'{name} failed')


def start_endpoint(
    runner: Runner, cleanup: ExitStack, name: str, plan: Path, device: str, selector: str
) -> subprocess.Popen[bytes]:
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(plan),
               '-destination', 'platform=iOS Simulator,id=' + device,
               '-parallel-testing-enabled', 'NO', '-only-testing:' + selector]
    with (runner.out / f'{name}.log').open('wb') as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    identity: ProcessIdentity | None = None

    def stop() -> None:
        if process.poll() is None:
            error = runner.stop(process, identity)
            if error:
                runner.record(name + '-cleanup', [], 'failed', 1, time.monotonic(), error)

    cleanup.callback(stop)
    identity = process_snapshot().get(process.pid)
    return process


def wait_for(log: Path, marker: str, *processes: subprocess.Popen[bytes]) -> None:
    deadline = time.monotonic() + 100
    while marker not in log.read_text(errors='replace'):
        if any(process.poll() is not None for process in processes):
            raise RuntimeError(f'Test stopped before {marker}')
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Test did not reach {marker}')
        time.sleep(0.2)


def configure_receiver(runner: Runner, device: str, identifier: str, cleanup: ExitStack) -> tuple[Path, Path]:
    scheme = 'RideIntercom'
    destination = 'platform=iOS Simulator,id=' + device
    configuration = scheme_configuration(ROOT, scheme)
    settings = xcode_build_settings(ROOT, scheme, destination, configuration)
    run(runner, 'build-receiver', ['xcodebuild', 'build-for-testing', '-project', 'RideIntercom.xcodeproj',
        '-scheme', scheme, '-destination', destination, '-configuration', configuration], timeout=420)
    source = select_test_run(settings, scheme)
    if source is None:
        raise RuntimeError('The shared app scheme did not create a test plan')
    plan = source.parent / f'diagnostics-receiver-{identifier}.xctestrun'
    data = plistlib.loads(source.read_bytes())
    target = next(target for config in data['TestConfigurations'] for target in config['TestTargets']
                  if target['BlueprintName'] == 'RideIntercomUITests')
    target.setdefault('EnvironmentVariables', {})['RIDEINTERCOM_PAIRED_DIAGNOSTICS'] = '1'
    with plan.open('xb') as stream:
        plistlib.dump(data, stream)
    cleanup.callback(plan.unlink, missing_ok=True)
    if not runner.check_test_host('receiver-host', plan, settings['RIDEINTERCOM_STORAGE_NAMESPACE']):
        raise RuntimeError('The receiver must use the isolated validation host')
    app = Path(settings['TARGET_BUILD_DIR']) / settings['FULL_PRODUCT_NAME']
    run(runner, 'receiver-install', ['xcrun', 'simctl', 'install', device, str(app)])
    environment = os.environ | {
        'SIMCTL_CHILD_RIDEINTERCOM_LOCAL_TESTING': '1',
        'SIMCTL_CHILD_RIDEINTERCOM_ACCOUNT_FIXTURE': 'signed-in',
        'SIMCTL_CHILD_RIDEINTERCOM_INTERFACE_FIXTURE': 'advanced',
        'SIMCTL_CHILD_RIDEINTERCOM_BACKGROUND_OBSERVATION': '1',
    }
    if not runner.run('receiver-launch', ['xcrun', 'simctl', 'launch', device, APP,
            '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'], timeout=30, env=environment):
        raise RuntimeError('Could not launch the isolated receiver before the UI test')
    return plan, Path(settings['BUILD_DIR'])


def check_endpoint(runner: Runner, name: str, process: subprocess.Popen[bytes],
                   build_dir: Path, selector: str) -> None:
    started = time.monotonic()
    code = process.wait(timeout=40)
    runner.record(name, [], 'passed' if code == 0 else 'failed', code, started)
    if code:
        raise RuntimeError(f'{name} tests failed')
    result = xcode_test_result(runner.out / f'{name}.log', build_dir)
    run(runner, name + '-summary', ['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
        '--path', str(result), '--compact'])
    summary = json.loads((runner.out / f'{name}-summary.log').read_text())
    if not xcode_tests_passed(summary) or summary['totalTestCount'] != 1:
        raise RuntimeError(f'{name} did not pass exactly one test')
    if not runner.check_test_selection(name, result, [selector]):
        raise RuntimeError(f'{name} ran an unexpected test')


def open_invitation(receiver: str, invitation: Path) -> None:
    # A timeout exception includes argv. Keep the synthetic invitation out of
    # command logs, evidence files and the error returned to the runner.
    try:
        result = subprocess.run(['xcrun', 'simctl', 'openurl', receiver, invitation.read_text()],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError('Could not open the synthetic invitation on the owned receiver') from None
    if result.returncode:
        raise RuntimeError('Could not open the synthetic invitation on the owned receiver')


def matching_output(
    observations: list[dict], displayed_at: float, audible_age: int, render_age: int, passing: bool
) -> dict | None:
    for row in reversed(observations):
        if not row.get('outputCallback') or not row.get('usesNativeOutput') or not row.get('muted'):
            continue
        output = row.get('nativeOutput')
        audible_at = row.get('lastNativeAudibleOutputAt')
        if not isinstance(output, dict) or not isinstance(audible_at, (int, float)):
            continue
        if abs(row['recordedAt'] - displayed_at) > 1.5 or output['audibleDuration'] <= 0:
            continue
        measured_age = displayed_at - audible_at
        if measured_age < 0 or render_age > 2 or abs(audible_age - measured_age) > 2:
            continue
        if passing and measured_age <= 2 and audible_age <= 2:
            return row
        if not passing and measured_age > 2 and audible_age >= 2:
            return row
    return None


def observe_output(log: Path, records: Path, phase: str) -> tuple[dict, dict]:
    passing = phase != 'AUDIO_IDLE'
    state = 'Passing' if passing else 'Waiting'
    match = re.search(OUTPUT_LINE.format(phase=phase, state=state), log.read_text(errors='replace'))
    if match is None:
        raise RuntimeError(f'{phase}: Output did not report audible PCM and render ages')
    shown_at, audible, render = float(match[1]), int(match[2]), int(match[3])
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if records.is_file():
            observed = matching_output(json.loads(records.read_text()), shown_at, audible, render, passing)
            if observed is not None:
                return observed, {'phase': phase, 'output': state, 'displayedAudibleAge': audible,
                                  'displayedRenderAge': render,
                                  'nativeAudibleAge': round(shown_at - observed['lastNativeAudibleOutputAt'], 3),
                                  'nativeRenderCallbacks': observed['nativeOutput']['callbackCount'],
                                  'nativeAudibleSeconds': round(observed['nativeOutput']['audibleDuration'], 3)}
        time.sleep(0.1)
    raise RuntimeError(f'{phase}: no matching native output observation')


def verify_output_sequence(first: dict, idle: dict, resumed: dict) -> None:
    for field in ('processInstance', 'connectionInstance', 'deadline'):
        if not (first[field] == idle[field] == resumed[field]):
            raise RuntimeError('The receiver changed call or restarted while observing Output')
    outputs = [row['nativeOutput'] for row in (first, idle, resumed)]
    if len({output['instance'] for output in outputs}) != 1:
        raise RuntimeError('The native renderer restarted while observing Output')
    if not outputs[0]['callbackCount'] < outputs[1]['callbackCount'] < outputs[2]['callbackCount']:
        raise RuntimeError('The native renderer did not run through silence and resumed speech')
    if not (resumed['lastNativeAudibleOutputAt'] > idle['lastNativeAudibleOutputAt']
            and outputs[2]['audibleDuration'] > outputs[1]['audibleDuration']):
        raise RuntimeError('Output returned to Passing without new native audible PCM')


def output_after_runner(observations: list[dict], before: dict, finished_at: float) -> dict | None:
    for row in reversed(observations):
        if (row['recordedAt'] <= finished_at or not row['muted'] or not row['outputCallback']
                or not row['usesNativeOutput'] or row['authenticatedPeers'] != 1):
            continue
        if any(row[field] != before[field] for field in ('processInstance', 'connectionInstance', 'deadline')):
            raise RuntimeError('The receiver changed call or restarted after the UI test')
        output = row['nativeOutput']
        audible_at = row['lastNativeAudibleOutputAt']
        if (isinstance(output, dict) and isinstance(audible_at, (int, float)) and audible_at > finished_at
                and output['instance'] == before['nativeOutput']['instance']
                and output['audibleDuration'] > before['nativeOutput']['audibleDuration']):
            return row
    return None


def exercise(runner: Runner, receiver: str, sender: str, cleanup: ExitStack) -> None:
    identifier = str(uuid.uuid4())
    settings, source = build_audio_host(runner, 'ios', 'platform=iOS Simulator,id=' + sender, 'Debug')
    environment = {'AUDIO_E2E_RUN': identifier, 'AUDIO_E2E_ROLE': 'b', 'AUDIO_E2E_TRANSPORT': 'local',
                   'AUDIO_E2E_STANDALONE_RECEIVER': '1', 'AUDIO_E2E_STANDALONE_DIAGNOSTICS': '1',
                   'AUDIO_E2E_SPEECH_PAIR': 'japanese', 'AUDIO_E2E_SCENARIOS': json.dumps(scenarios('smoke', 8))}
    plan = configure_test_run(source, 'diagnostics-' + identifier, 'ios',
                              settings['RIDEINTERCOM_STORAGE_NAMESPACE'], environment)
    cleanup.callback(plan.unlink, missing_ok=True)
    receiver_plan, receiver_build = configure_receiver(runner, receiver, identifier, cleanup)
    sending = start_endpoint(runner, cleanup, 'sender', plan, sender, SENDER_TEST)
    wait_for(runner.out / 'sender.log', 'AUDIO_E2E_STANDALONE_INVITE_READY', sending)
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sender, APP, 'data'],
                                        text=True, timeout=20).strip()
    control = Path(container) / 'tmp' / f'RideIntercom.AudioE2E.{identifier}.b'
    receiving = start_endpoint(runner, cleanup, 'receiver', receiver_plan, receiver, RECEIVER_TEST)
    log = runner.out / 'receiver.log'
    wait_for(log, 'RIDE_INSTALLED_INVITE_READY', sending, receiving)
    receiver_container = subprocess.check_output(
        ['xcrun', 'simctl', 'get_app_container', receiver, APP, 'data'], text=True, timeout=20).strip()
    records = Path(receiver_container) / 'tmp' / RECEIVER_OBSERVATION
    open_invitation(receiver, control / 'receiver-invitation.url')
    snapshots = []
    evidence = []
    for state, action in [('READY', 'join'), ('FIRST_AUDIO', 'pause'), ('AUDIO_IDLE', 'resume'), ('RESUMED', None)]:
        started = time.monotonic()
        wait_for(log, 'AUDIO_E2E_DIAGNOSTICS_' + state, sending, receiving)
        if state != 'READY':
            observed, summary = observe_output(log, records, state)
            snapshots.append(observed)
            evidence.append(summary)
        runner.record('rx-' + state.lower().replace('_', '-'), [], 'passed', 0, started)
        if action:
            (control / action).touch()
    verify_output_sequence(*snapshots)
    check_endpoint(runner, 'receiver', receiving, receiver_build, RECEIVER_TEST)
    finished_at = time.time()
    started = time.monotonic()
    while time.monotonic() - started < 8 and sending.poll() is None:
        observed = output_after_runner(json.loads(records.read_text()), snapshots[-1], finished_at)
        if observed is not None:
            evidence.append({'phase': 'AFTER_RECEIVER_RUNNER',
                             'recordedAfterRunnerSeconds': round(observed['recordedAt'] - finished_at, 3),
                             'nativeAudibleSeconds': round(observed['nativeOutput']['audibleDuration'], 3)})
            break
        time.sleep(0.1)
    else:
        raise RuntimeError('No new audible PCM in the same muted call after the receiver UI test')
    runner.record('rx-after-receiver-runner', [], 'passed', 0, started)
    (runner.out / 'native-output.json').write_text(json.dumps(evidence, indent=2) + '\n')
    (control / 'finish').touch()
    check_endpoint(runner, 'sender', sending, Path(settings['BUILD_DIR']), SENDER_TEST)


def boot(runner: Runner, role: str, device: str, cleanup: ExitStack) -> None:
    run(runner, role + '-boot', ['xcrun', 'simctl', 'boot', device])
    run(runner, role + '-ready', ['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=180)
    pin = SimulatorAudioPin(device)
    cleanup.callback(pin.restore)
    pin.pin()
    run(runner, role + '-microphone', ['xcrun', 'simctl', 'privacy', device, 'grant', 'microphone', APP])


def make_device(runner: Runner, role: str, runtime: str, cleanup: ExitStack) -> str:
    journal = simulator_resource_root() / f'diagnostics-audio-{role}.json'
    lease = SimulatorLease(runner, journal, stage=role)
    if lease.state and not lease.cleanup(role + '-recovery'):
        raise RuntimeError(f'Could not recover the owned {role} simulator')
    name = f'RideIntercom Validation Audio Diagnostics {role} ' + uuid.uuid4().hex[:8]
    lease.reserve(name)
    cleanup.callback(lease.cleanup, role + '-cleanup')
    return lease.create_reserved(runtime, IPHONE_DEVICE_TYPE)


def main() -> int:
    resource_root = simulator_resource_root()
    validation = ROOT / '.validation'
    validation.mkdir(exist_ok=True)
    runner = Runner(Path(tempfile.mkdtemp(prefix='diagnostics-audio-', dir=validation)))
    print('Evidence:', runner.out, flush=True)
    try:
        with exclusive_run(resource_root / 'run.lock'), ExitStack() as cleanup:
            before = source_manifest(ROOT)
            run(runner, 'runtimes', ['xcrun', 'simctl', 'list', 'runtimes', '-j'])
            runtimes = json.loads((runner.out / 'runtimes.log').read_text())['runtimes']
            runtime = latest_runtime(runtimes, 'iOS', IPHONE_DEVICE_TYPE)
            receiver_id = make_device(runner, 'receiver', runtime, cleanup)
            sender_id = make_device(runner, 'sender', runtime, cleanup)
            boot(runner, 'receiver', receiver_id, cleanup)
            boot(runner, 'sender', sender_id, cleanup)
            exercise(runner, receiver_id, sender_id, cleanup)
            after = source_manifest(ROOT)
            if before['head'] != after['head'] or not fingerprints_match(before['files'], after['files']):
                raise RuntimeError('Source changed while measuring the paired call')
            runner.record('paired-rx', [], 'passed', 0, time.monotonic())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        runner.record('paired-rx', [], 'failed', 1, time.monotonic(), str(error))
    except KeyboardInterrupt:
        runner.record('paired-rx', [], 'interrupted', 130, time.monotonic())
        return 130
    return runner.exit_code


if __name__ == '__main__':
    def interrupted(signum: int, frame: FrameType | None) -> None:
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
