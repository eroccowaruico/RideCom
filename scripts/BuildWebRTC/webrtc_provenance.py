"""Record a native build's tool versions and bind them to its output ZIP."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

PLATFORM_OUTPUTS = {
    'iphoneos': {'ios-arm64-device'},
    'iphonesimulator': {'ios-arm64-simulator', 'ios-x64-simulator'},
    'macosx': {'macos-arm64', 'macos-x64'},
}
BUILD_FIELDS = {
    'checksum': r'[0-9a-f]{64}',
    'upstream_revision': r'[0-9a-f]{40}',
    'depot_tools_revision': r'[0-9a-f]{40}',
    'source_policy': r'official-unmodified',
    'gn_version': r'\d{1,8} \([0-9a-f]{7,40}\)',
    'xcode_version': r'\d+(?:\.\d+){1,2}',
    'xcode_build': r'\d+[A-Za-z]\w{1,12}',
}


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1_048_576), b''):
            digest.update(block)
    return digest.hexdigest()


def verify_imported_checksum(zip_path: Path) -> None:
    lines = zip_path.with_suffix('.metadata').read_text().splitlines()
    checksums = [line.removeprefix('checksum=') for line in lines if line.startswith('checksum=')]
    if len(checksums) != 1 or not matches(checksums[0], BUILD_FIELDS['checksum']):
        raise ValueError('Imported WebRTC metadata must record one SHA-256 checksum')
    if file_sha256(zip_path) != checksums[0]:
        raise ValueError('WebRTC archive does not match imported metadata')


def provenance_path(zip_path: Path) -> Path:
    return zip_path.with_suffix('.provenance.json')


def matches(value: object, pattern: str) -> bool:
    return isinstance(value, str) and re.fullmatch(pattern, value, re.ASCII) is not None


def validate(data: object, checksum: str) -> dict[str, object]:
    if (not isinstance(data, dict) or set(data) != {*BUILD_FIELDS, 'sdks', 'gn_args_sha256'}
            or not all(matches(data[field], pattern) for field, pattern in BUILD_FIELDS.items())):
        raise ValueError('Invalid WebRTC build provenance fields')
    sdks = data['sdks']
    arguments = data['gn_args_sha256']
    if (not isinstance(sdks, dict) or not sdks.keys() <= PLATFORM_OUTPUTS.keys() or not sdks
            or ('iphoneos' in sdks) != ('iphonesimulator' in sdks)
            or not all(matches(version, BUILD_FIELDS['xcode_version']) for version in sdks.values())
            or not isinstance(arguments, dict)
            or set(arguments) != set().union(*(PLATFORM_OUTPUTS[sdk] for sdk in sdks))
            or not all(matches(value, BUILD_FIELDS['checksum']) for value in arguments.values())):
        raise ValueError('Invalid WebRTC build provenance platforms')
    if data['checksum'] != checksum:
        raise ValueError('WebRTC build provenance does not match the ZIP checksum')
    return data


def read_provenance(zip_path: Path, checksum: str) -> dict[str, object]:
    companion = provenance_path(zip_path)
    if not companion.exists() and not companion.is_symlink():
        raise ValueError('Missing WebRTC build provenance for a new import')
    if companion.is_symlink() or not companion.is_file() or companion.stat().st_size > 4096:
        raise ValueError('Invalid WebRTC build provenance file')
    try:
        data: object = json.loads(companion.read_bytes())
    except (UnicodeError, ValueError) as error:
        raise ValueError('Invalid WebRTC build provenance JSON') from error
    return validate(data, checksum)


def output(*command: str) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip()


def record(zip_path: Path, upstream: str, depot: str, platforms: list[str]) -> None:
    version = re.fullmatch(r'Xcode (\S+)\nBuild version (\S+)', output('xcodebuild', '-version'))
    if version is None:
        raise ValueError('Xcode did not report version and build')
    version_number, build = version.groups()
    sdks = {sdk: output('xcrun', '--sdk', sdk, '--show-sdk-version') for sdk in platforms}
    checksum = file_sha256(zip_path)
    data = validate({
        'checksum': checksum,
        'upstream_revision': upstream,
        'depot_tools_revision': depot,
        'source_policy': 'official-unmodified',
        'gn_version': output('gn', '--version'),
        'xcode_version': version_number,
        'xcode_build': build,
        'sdks': sdks,
        'gn_args_sha256': {name: file_sha256(zip_path.parent / name / 'args.gn')
                          for sdk in platforms for name in PLATFORM_OUTPUTS[sdk]},
    }, checksum)
    with provenance_path(zip_path).open('x') as stream:
        stream.write(json.dumps(data, sort_keys=True) + '\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zip', type=Path)
    parser.add_argument('upstream_revision')
    parser.add_argument('depot_tools_revision')
    parser.add_argument('platforms', nargs='+', choices=PLATFORM_OUTPUTS)
    inputs = parser.parse_args()
    try:
        record(inputs.zip, inputs.upstream_revision, inputs.depot_tools_revision, inputs.platforms)
    except (OSError, ValueError, subprocess.CalledProcessError):
        parser.exit(1, 'WebRTC build provenance could not be recorded.\n')


if __name__ == '__main__':
    main()
