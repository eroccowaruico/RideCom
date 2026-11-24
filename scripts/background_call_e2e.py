"""Opt-in native background waiting evidence; uses the Xcode UI-test entry point."""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.simulator_audio import SimulatorAudioPin
from scripts.test_lifecycle import (
    SimulatorLease,
    exclusive_run,
    simulator_resource_root,
)
from scripts.validate import ROOT, Runner, snapshot


def archive_observations(runner: Runner, sim: str, cases: list[str]) -> None:
    started = time.monotonic()
    container = subprocess.run(
        ['xcrun', 'simctl', 'get_app_container', sim, 'com.yowamushi-inc.RideIntercom.RideIntercom', 'data'],
        capture_output=True, text=True, check=False,
    )
    missing = []
    for layout in ['standard', 'advanced']:
        for suffix in cases:
            variant = f'{layout}-{suffix}'
            name = f'background-call-{variant}.json'
            source = Path(container.stdout.strip()) / 'tmp' / name
            if container.returncode == 0 and source.is_file():
                shutil.copyfile(source, runner.out / name)
            else:
                missing.append(variant)
    runner.record('background-observations', [], 'failed' if missing else 'passed', int(bool(missing)), started,
                  'missing evidence: ' + ', '.join(missing) if missing else '')


def main() -> int:
    os.environ['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    os.environ['CI'] = '1'
    parser = argparse.ArgumentParser(
        description='Native iOS waiting audio during background, without a peer; not physical-device acceptance'
    )
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--reuse-settings', type=Path)
    parser.add_argument('--scenario', choices=['waiting','resumed','first-permission','all'], default='waiting')
    args=parser.parse_args()
    root=ROOT
    cases = {'waiting': ['open', 'muted'], 'resumed': ['resumed'], 'first-permission': ['first-permission'],
             'all': ['open', 'muted', 'resumed', 'first-permission']}[args.scenario]
    tests=[]
    for layout in ['Standard','Advanced']:
        for variant in cases:
            method=('test'+layout+'WaitingReturnsFromBackgroundWithoutLosingItsCall' if variant=='open' else
                    'test'+layout+'MutedWaitingKeepsAudioInBackground' if variant=='muted' else
                    'test'+layout+'FirstMicrophonePermissionContinuesInBackground' if variant=='first-permission' else
                    'test'+layout+'ResumeWhileWaitingContinuesInBackground')
            tests.append('RideIntercomUITests/BackgroundCallLifecycleUITests/'+method)
    os.chdir(root)
    runner=Runner(args.out.resolve(), timeout=1200)
    snapshot(runner.out)
    with exclusive_run(simulator_resource_root()/'run.lock'):
        lease=SimulatorLease(runner, simulator_resource_root()/'reusable.json')
        audio_pin=None
        try:
            runner.run('runtimes',['xcrun','simctl','list','runtimes','-j'],timeout=60)
            available=[r for r in json.loads((runner.out/'runtimes.log').read_text())['runtimes'] if r['isAvailable'] and r['name'].startswith('iOS')]
            runtime=max(available,key=lambda r:tuple(map(int,r['version'].split('.'))))['identifier']
            sim=lease.prepare(runtime,'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')
            if not sim: raise RuntimeError('No simulator lease')
            (runner.out/'simulator-id.txt').write_text(sim+'\n')
            runner.run('boot',['xcrun','simctl','boot',sim],timeout=120)
            runner.run('ready',['xcrun','simctl','bootstatus',sim,'-b'],needs=['boot'],timeout=180)
            runner.run('appearance',['xcrun','simctl','ui',sim,'appearance','light'],needs=['ready'],timeout=30)
            audio_pin=SimulatorAudioPin(sim)
            (runner.out/'simulator-duplex-device.txt').write_text(audio_pin.pin()+'\n')
            reuse=args.reuse_settings
            if reuse:
                shutil.copyfile(reuse, runner.out/'reused-build-build-settings.json')
            permission='reset' if args.scenario in ['first-permission','all'] else 'grant'
            runner.run('microphone-permission',['xcrun','simctl','privacy',sim,permission,'microphone','com.yowamushi-inc.RideIntercom.RideIntercom'],needs=['ready'],timeout=30)
            prior=subprocess.run(['xcrun','simctl','get_app_container',sim,'com.yowamushi-inc.RideIntercom.RideIntercom','data'],capture_output=True,text=True,check=False)
            if prior.returncode==0:
                for old in (Path(prior.stdout.strip())/'tmp').glob('background-call-*.json'):
                    old.unlink()
            runner.xcode('ui', 'platform=iOS Simulator,id=' + sim, only=tests,
                         needs=['appearance', 'microphone-permission'], verify_selection=True,
                         reuse_build='reused-build' if reuse else None)
            archive_observations(runner, sim, cases)
        finally:
            try:
                if audio_pin: audio_pin.restore()
            finally:
                if lease.acquired: lease.cleanup('simulator-final')
    return runner.exit_code


if __name__ == '__main__':
    sys.exit(main())
