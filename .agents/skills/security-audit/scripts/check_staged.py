"""Inspect staged changes or the committed project locally. Emit only a closed vocabulary."""
import json
import os
import re
import subprocess
import sys

MAX_BYTES = 2 * 1024 * 1024
# Flags are review signals. Unknown formats and operational controls need separate evidence.
PATTERNS = {
    'private-key': re.compile(rb'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----'),
    'credential': re.compile(
        rb'\b(?:gh[pousr]_[a-z0-9]{24,}|github_pat_[a-z0-9_]{30,}|'
        rb'sk-[a-z0-9_-]{24,}|(?:AKIA|ASIA)[A-Z0-9]{16}|'
        rb'eyJ[a-z0-9_-]{6,}\.eyJ[a-z0-9_-]{6,}\.[a-z0-9_-]{8,}|'
        rb'bearer[ \t]+[a-z0-9._~+/-]{12,})\b|'
        rb'\b(?:[a-z0-9_-]{0,64}(?:token|password|api[_-]?key|client[_-]?secret))'
        rb"""["']?\s*[:=]\s*["'][a-z0-9._~+/=-]{12,}["']""",
        re.IGNORECASE),
    'personal-data': re.compile(
        rb'[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,253}\.[a-z]{2,}|/(?:Users|home)/[\w.-]+', re.IGNORECASE),
}


def git(*args):
    # No inherited tokens, tracing, replacement objects, external diff or lazy network fetch.
    return subprocess.run(
        ['/usr/bin/git', '--no-replace-objects', '-c', 'core.fsmonitor=false', *args],
        env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'GIT_CONFIG_NOSYSTEM': '1',
             'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_ALLOW_PROTOCOL': '', 'GIT_NO_LAZY_FETCH': '1',
             'GIT_TERMINAL_PROMPT': '0', 'GIT_OPTIONAL_LOCKS': '0'},
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        check=True, timeout=30).stdout


def detect(data, signals):
    for label, pattern in PATTERNS.items():
        if pattern.search(data):
            signals.add(label)


def sensitive_path(path):
    components = path.lower().split(b'/')
    name = components[-1]
    return (name == b'.env' or name.startswith((b'.env.', b'.dev.vars')) or
            name.endswith((b'.p8', b'.p12', b'.pfx', b'.pem', b'.key', b'.mobileprovision')) or
            name in (b'id_rsa', b'id_ed25519', b'.netrc', b'.npmrc') or
            any(part in (b'.ssh', b'.aws', b'.gnupg') for part in components))


def snapshot_entries(project):
    if project:
        tree = git('ls-tree', '--full-tree', '-r', '-l', '-z', 'HEAD')
        for record in tree.split(b'\0')[:-1]:
            header, path = record.split(b'\t', 1)
            mode, _, oid, size = header.split()
            yield path, mode, oid, b'M', int(size) if size.isdigit() else None
        return
    entries = git('diff', '--cached', '--raw', '-z', '--abbrev=64', '--no-renames',
                  '--no-relative', '--no-ext-diff', '--no-textconv', '--ignore-submodules=none', '--')
    fields = entries.split(b'\0')
    if fields.pop() or len(fields) % 2:
        raise ValueError
    for header, path in zip(fields[::2], fields[1::2]):
        _, mode, _, oid, status = header.split()
        yield path, mode, oid, status, None


def area(path):
    if path.startswith(b'RideIntercom/packages/'):
        return 'packages'
    top = path.split(b'/')[0]
    return {b'RideIntercom': 'app', b'RideIntercomWidgets': 'extensions',
            b'RideIntercomWatch': 'extensions', b'Configuration': 'build', b'server': 'server',
            b'.github': 'ci', b'.agents': 'audit', b'scripts': 'tooling', b'docs': 'docs',
            b'RideIntercom.xcodeproj': 'build', b'RideIntercomTests': 'tests',
            b'RideIntercomUITests': 'tests', b'RideIntercomAudioE2ETests': 'tests',
            b'RideIntercomWatchUITests': 'tests'}.get(top, 'other')


def inspect_snapshot(option):
    if any(key in os.environ for key in (
        'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
        'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE',
    )):
        raise ValueError
    signals, changes = set(), {}
    seen = False
    for path, mode, oid, status, size in snapshot_entries(option == '--project'):
        seen = True
        if option == '--changes':
            action = {b'A': 'add', b'M': 'modify', b'T': 'replace', b'D': 'remove'}.get(status, 'unknown')
            changes.setdefault(area(path), set()).add(action)
        detect(path, signals)
        if status == b'D':
            continue
        if status not in (b'A', b'M', b'T') or mode not in (b'100644', b'100755'):
            signals.add('opaque')
            continue
        if sensitive_path(path):
            signals.add('sensitive-file')
            continue
        if not re.fullmatch(rb'[a-f0-9]{40}|[a-f0-9]{64}', oid):
            raise ValueError
        if size is None:
            size = int(git('cat-file', '-s', oid))
        if size > MAX_BYTES:
            signals.add('opaque')
            continue
        blob = git('cat-file', 'blob', oid)
        try:
            blob.decode('utf-8')
        except UnicodeDecodeError:
            signals.add('opaque')
            continue
        if b'\0' in blob:
            signals.add('opaque')
            continue
        detect(blob, signals)
    state = 'empty' if not seen else 'review' if signals else 'checked'
    report = {'state': state, 'signals': sorted(signals)}
    if option == '--changes':
        report['changes'] = {key: sorted(actions) for key, actions in changes.items()}
    return report


def main():
    try:
        args = sys.argv[1:]
        if args not in ([], ['--project'], ['--changes']):
            raise ValueError
        report = inspect_snapshot(args[0] if args else None)
    except (OSError, ValueError, subprocess.SubprocessError):
        report = {'state': 'unavailable', 'signals': []}
    print(json.dumps(report, sort_keys=True))
    state = report['state']
    return {'empty': 0, 'checked': 0, 'review': 1, 'unavailable': 2}[state]


if __name__ == '__main__':
    sys.exit(main())
