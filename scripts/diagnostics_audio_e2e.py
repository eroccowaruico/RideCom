#!/usr/bin/env python3
"""Observe RX diagnostics through a received speech, silence, and speech sequence."""
from __future__ import annotations

import json
import plistlib
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


def configure_receiver(runner: Runner, destination: str, identifier: str, cleanup: ExitStack) -> tuple[Path, Path]:
    scheme = 'RideIntercom'
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


def exercise(runner: Runner, receiver: str, sender: str, cleanup: ExitStack) -> None:
    identifier = str(uuid.uuid4())
    settings, source = build_audio_host(runner, 'ios', 'platform=iOS Simulator,id=' + sender, 'Debug')
    environment = {'AUDIO_E2E_RUN': identifier, 'AUDIO_E2E_ROLE': 'b', 'AUDIO_E2E_TRANSPORT': 'local',
                   'AUDIO_E2E_STANDALONE_RECEIVER': '1', 'AUDIO_E2E_STANDALONE_DIAGNOSTICS': '1',
                   'AUDIO_E2E_SPEECH_PAIR': 'japanese', 'AUDIO_E2E_SCENARIOS': json.dumps(scenarios('smoke', 8))}
    plan = configure_test_run(source, 'diagnostics-' + identifier, 'ios',
                              settings['RIDEINTERCOM_STORAGE_NAMESPACE'], environment)
    cleanup.callback(plan.unlink, missing_ok=True)
    receiver_plan, receiver_build = configure_receiver(
        runner, 'platform=iOS Simulator,id=' + receiver, identifier, cleanup)
    sending = start_endpoint(runner, cleanup, 'sender', plan, sender, SENDER_TEST)
    wait_for(runner.out / 'sender.log', 'AUDIO_E2E_STANDALONE_INVITE_READY', sending)
    container = subprocess.check_output(['xcrun', 'simctl', 'get_app_container', sender, APP, 'data'],
                                        text=True, timeout=20).strip()
    control = Path(container) / 'tmp' / f'RideIntercom.AudioE2E.{identifier}.b'
    receiving = start_endpoint(runner, cleanup, 'receiver', receiver_plan, receiver, RECEIVER_TEST)
    log = runner.out / 'receiver.log'
    wait_for(log, 'RIDE_INSTALLED_INVITE_READY', sending, receiving)
    open_invitation(receiver, control / 'receiver-invitation.url')
    for state, action in [('READY', 'join'), ('FIRST_AUDIO', 'pause'), ('AUDIO_IDLE', 'resume'),
                          ('RESUMED', 'finish')]:
        started = time.monotonic()
        wait_for(log, 'AUDIO_E2E_DIAGNOSTICS_' + state, sending, receiving)
        runner.record('rx-' + state.lower().replace('_', '-'), [], 'passed', 0, started)
        (control / action).touch()
    check_endpoint(runner, 'sender', sending, Path(settings['BUILD_DIR']), SENDER_TEST)
    check_endpoint(runner, 'receiver', receiving, receiver_build, RECEIVER_TEST)


def boot(runner: Runner, role: str, device: str, cleanup: ExitStack) -> None:
    run(runner, role + '-boot', ['xcrun', 'simctl', 'boot', device])
    run(runner, role + '-ready', ['xcrun', 'simctl', 'bootstatus', device, '-b'], timeout=180)
    pin = SimulatorAudioPin(device)
    cleanup.callback(pin.restore)
    pin.pin()
    run(runner, role + '-microphone', ['xcrun', 'simctl', 'privacy', device, 'grant', 'microphone', APP])


def make_device(runner: Runner, role: str, runtime: str, cleanup: ExitStack) -> str:
    journal = simulator_resource_root() / f'diagnostics-audio-{role}.json'
    lease = SimulatorLease(runner, journal)
    if lease.state and not lease.cleanup(role + '-recovery'):
        raise RuntimeError(f'Could not recover the owned {role} simulator')
    name = f'RideIntercom Validation Audio Diagnostics {role} ' + uuid.uuid4().hex[:8]
    lease.reserve(name)
    cleanup.callback(lease.cleanup, role + '-cleanup')
    run(runner, role + '-create', ['xcrun', 'simctl', 'create', name, IPHONE_DEVICE_TYPE, runtime])
    device = (runner.out / f'{role}-create.log').read_text().strip()
    lease.identify(device)
    return device


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
