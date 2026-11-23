import argparse
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from scripts.test_lifecycle import exclusive_run, simulator_devices, simulator_resource_root

PREVIEW = 'https://preview-rideintercom.analog.workers.dev'
CASE = 'RideIntercomAudioE2ETests/AudioE2ETests/testWebRTCDuplexSpeechWithoutAudioHardware'


def status(token):
    config = f'header = "Authorization: Bearer {token}"\n'
    result = subprocess.run(
        ['/usr/bin/curl', '--config', '-', '--silent', '--proto', '=https', '--max-time', '10',
         '--write-out', '\n%{http_code}', PREVIEW + '/api/status'],
        input=config, text=True, capture_output=True, timeout=15)
    body, _, code = result.stdout.rpartition('\n')
    if result.returncode or not re.fullmatch(r'[0-9]{3}', code):
        return 0, None
    return int(code), json.loads(body) if code == '200' else None


def simulator_test(output, bootstrap, require_turn):
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))['runtimes']
    runtime = max((row for row in runtimes if row['isAvailable'] and row['name'].startswith('iOS')),
                  key=lambda row: tuple(map(int, row['version'].split('.'))))['identifier']
    name = 'RideIntercom Preview Media ' + uuid.uuid4().hex[:8]
    device = subprocess.check_output(
        ['xcrun', 'simctl', 'create', name, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime],
        text=True, timeout=30).strip()
    log = output / 'xcodebuild.log'
    try:
        command = ['xcodebuild', '-project', 'RideIntercom.xcodeproj', '-scheme', 'RideIntercomAudioE2E',
                   '-destination', 'platform=iOS Simulator,id=' + device, '-parallel-testing-enabled', 'NO',
                   '-resultBundlePath', str(output / 'media.xcresult'), '-only-testing:' + CASE, 'test']
        environment = os.environ | {'TEST_RUNNER_RIDEINTERCOM_PREVIEW_MEDIA_BOOTSTRAP': bootstrap}
        environment['TEST_RUNNER_RIDEINTERCOM_TEST_TURN_RELAY'] = '1' if require_turn else '0'
        with log.open('w') as stream:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=420)
    finally:
        owned = next((row for row in simulator_devices() if row['udid'] == device and row['name'] == name), None)
        if owned:
            if owned['state'] != 'Shutdown':
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], check=True, capture_output=True, timeout=45)
            subprocess.run(['xcrun', 'simctl', 'delete', device], check=True, capture_output=True, timeout=45)
    log_text = log.read_text(errors='replace')
    counts = re.search(r'WebRTC speech frames: left \d+/\d+, right \d+/\d+', log_text)
    if counts:
        print(counts[0])
    relay_checks = log_text.count('WebRTC UDP TURN selected: left true, right true')
    if require_turn:
        print(f'UDP TURN selected on both legs: {relay_checks}/2')
    return result.returncode == 0 and counts is not None and (not require_turn or relay_checks == 2)


def run_trial(data, output, require_turn):
    before_code, before = status(data['leftToken'])
    second_code, _ = status(data['rightToken'])
    print(f'Preview authorization: {before_code} {second_code}', flush=True)
    if before_code != 200 or second_code != 200:
        return 1
    secret_path = '/' + secrets.token_urlsafe(32)
    response = json.dumps(data).encode()
    mutex = threading.Lock()
    issued = False

    class Bootstrap(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            nonlocal issued
            with mutex:
                if issued or self.path != secret_path:
                    self.send_error(404)
                    return
                issued = True
            self.send_response(200)
            self.send_header('Content-Length', str(len(response)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(response)

    with exclusive_run(simulator_resource_root() / 'run.lock'):
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Bootstrap) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                succeeded = simulator_test(output, f'http://127.0.0.1:{server.server_port}{secret_path}', require_turn)
            except subprocess.TimeoutExpired:
                print('The Simulator trial reached its execution deadline', flush=True)
                succeeded = False
            finally:
                server.shutdown()
                thread.join()
    for _ in range(6):
        after_code, after = status(data['leftToken'])
        if after_code == 200 and after['activeSessions'] <= before['activeSessions']:
            break
        time.sleep(3)
    if after_code == 200:
        print(f"Preview sessions: {before['activeSessions']} -> {after['activeSessions']}")
        print(f"Participant seconds reserved: {after['reservedParticipantSeconds'] - before['reservedParticipantSeconds']}")
    return int(not (succeeded and issued and after_code == 200 and after['activeSessions'] <= before['activeSessions']))


def main():
    parser = argparse.ArgumentParser(description='Run one two-participant speech trial against the fixed Preview')
    parser.add_argument('credentials', type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--output', type=Path)
    mode.add_argument('--check-revoked', action='store_true')
    parser.add_argument('--turn-relay', action='store_true', help='Require both selected ICE paths to use UDP TURN')
    args = parser.parse_args()
    if args.turn_relay and args.check_revoked:
        parser.error('--turn-relay requires --output')
    metadata = args.credentials.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.getuid():
        parser.error('Use a private credential file')
    data = json.loads(args.credentials.read_text())
    if set(data) != {'leftToken', 'rightToken', 'room', 'groupSecret'} or not all(
        re.fullmatch(r'preview-media\.[a-zA-Z0-9_-]{43}', data[role]) for role in ('leftToken', 'rightToken')
    ):
        parser.error('Use the credentials made by prepare-preview-media-trial.mjs')
    if args.check_revoked:
        codes = [status(data[role])[0] for role in ('leftToken', 'rightToken')]
        print(f'Preview authorization after withdrawal: {codes[0]} {codes[1]}')
        return int(codes != [401, 401])
    os.umask(0o077)
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    output = args.output.resolve()
    output.mkdir()
    return run_trial(data, output, args.turn_relay)


if __name__ == '__main__':
    raise SystemExit(main())
