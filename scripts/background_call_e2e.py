#!/usr/bin/env python3
"""Opt-in native background waiting evidence; uses the Xcode UI-test entry point."""
import os, sys, json, shutil, subprocess, time
import argparse
from pathlib import Path
os.environ['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
os.environ['CI']='1'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.validate import ROOT, Runner, snapshot
from scripts.test_lifecycle import exclusive_run, simulator_resource_root, SimulatorLease
parser=argparse.ArgumentParser(description="Native iOS waiting audio during background, without a peer; not physical-device acceptance")
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--reuse-settings', type=Path)
parser.add_argument('--scenario', choices=['waiting','resumed','first-permission','all'], default='waiting')
args=parser.parse_args()
root=ROOT
cases={'waiting':[('open',False),('muted',True)],'resumed':[('resumed',False)],
       'first-permission':[('first-permission',False)],
       'all':[('open',False),('muted',True),('resumed',False),('first-permission',False)]}[args.scenario]
tests=[]
for layout in ['Standard','Advanced']:
    for variant,_ in cases:
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
        from scripts.audio_e2e import SimulatorAudioPin, run_devicectl_json
        audio_pin=SimulatorAudioPin(sim,run_devicectl_json)
        (runner.out/'simulator-duplex-device.txt').write_text(audio_pin.pin()+'\n')
        reuse=args.reuse_settings
        if reuse:
            import shutil
            shutil.copyfile(reuse, runner.out/'reused-build-build-settings.json')
        permission='reset' if args.scenario in ['first-permission','all'] else 'grant'
        runner.run('microphone-permission',['xcrun','simctl','privacy',sim,permission,'microphone','com.yowamushi-inc.RideIntercom.RideIntercom'],needs=['ready'],timeout=30)
        prior=subprocess.run(['xcrun','simctl','get_app_container',sim,'com.yowamushi-inc.RideIntercom.RideIntercom','data'],capture_output=True,text=True)
        if prior.returncode==0:
            for old in (Path(prior.stdout.strip())/'tmp').glob('background-call-*.json'):
                old.unlink()
        runner.xcode('ui','platform=iOS Simulator,id='+sim, only=tests,needs=['ready'],
                     reuse_build='reused-build' if reuse else None)
        import subprocess, shutil
        container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',sim,'com.yowamushi-inc.RideIntercom.RideIntercom','data'],text=True).strip())
        found=[]
        for layout in ['standard','advanced']:
            for suffix,muted in cases:
                variant=layout+'-'+suffix
                source=container/'tmp'/('background-call-'+variant+'.json')
                outcome=dict(variant=variant,passed=False)
                if source.is_file():
                    shutil.copyfile(source,runner.out/source.name)
                    rows=json.loads(source.read_text())
                    context_ok=bool(rows) and len({v.get('processInstance') for v in rows})==1 and all(
                        v.get('platform')=='simulator' and isinstance(v.get('processInstance'),str)
                        and isinstance(v.get('processID'),int) and isinstance(v.get('recordedAt'),(float,int))
                        and isinstance(v.get('protectedDataAvailable'),bool)
                        and v.get('microphonePermission') in ['undetermined','denied','granted','unknown']
                        and (v.get('debuggerAttached') is None or isinstance(v.get('debuggerAttached'),bool))
                        and isinstance(v.get('testRunnerPresent'),bool) for v in rows)
                    # With no remote source, AVAudioEngine need not deliver silent output taps.
                    # Observe native capture when unmuted, render when capture delivery is muted.
                    kinds=['outputCallback'] if muted else ['inputCallback']
                    details=[]
                    for kind in kinds:
                        samples=[v for v in rows if v['background'] and v.get(kind)]
                        span=samples[-1]['uptime']-samples[0]['uptime'] if samples else 0
                        ok=len(samples)>=20 and span>=29 and len({v['deadline'] for v in samples})==1 and all(v['audioReady'] and v['inputRunning'] and v['outputRunning'] and not v['mediaStarted'] and v['authenticatedPeers']==0 and v['muted']==muted and v['microphonePermission']=='granted' for v in samples)
                        details.append(dict(kind=kind,samples=len(samples),span=span,passed=ok))
                    outcome.update(passed=context_ok and all(v['passed'] for v in details),observations=details,
                                   runtimeContextValid=context_ok)
                else:
                    outcome['reason']='missing evidence'
                found.append(outcome)
                runner.record('background-native-'+variant,[],'passed' if outcome['passed'] else 'failed',0 if outcome['passed'] else 1,time.monotonic(),json.dumps(outcome))
        (runner.out/'background-observation-summary.json').write_text(json.dumps(found,indent=2)+'\n')
    finally:
        try:
            if audio_pin: audio_pin.restore()
        finally:
            if lease.acquired: lease.cleanup('simulator-final')
sys.exit(runner.exit_code)
