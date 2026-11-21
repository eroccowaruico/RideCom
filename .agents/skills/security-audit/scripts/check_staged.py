"""Inspect new Git index blobs locally. Emit only a closed vocabulary."""
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


def inspect_index():
    # The evidence must describe the same index that will be committed.
    if any(key in os.environ for key in (
        'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR',
        'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_NAMESPACE',
    )):
        raise ValueError
    entries = git('diff', '--cached', '--raw', '-z', '--abbrev=64', '--no-renames',
                  '--no-relative', '--no-ext-diff', '--no-textconv', '--ignore-submodules=none', '--')
    if not entries:
        return 'empty', set()
    fields = entries.split(b'\0')
    if fields.pop() or len(fields) % 2:
        raise ValueError
    signals = set()
    for header, path in zip(fields[::2], fields[1::2]):
        _, mode, _, oid, status = header.split()
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
        if int(git('cat-file', '-s', oid)) > MAX_BYTES:
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
    return ('review' if signals else 'checked'), signals


def main():
    try:
        state, signals = inspect_index()
    except (OSError, ValueError, subprocess.SubprocessError):
        state, signals = 'unavailable', set()
    print(json.dumps({'state': state, 'signals': sorted(signals)}))
    return {'empty': 0, 'checked': 0, 'review': 1, 'unavailable': 2}[state]


if __name__ == '__main__':
    sys.exit(main())
