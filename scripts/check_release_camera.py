"""Check a signed RideCom iOS archive, IPA, or exported App bundle for camera imports."""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
from pathlib import Path

from scripts.register_archive import APP_PATH, BUNDLE_ID, check_signature

MACHO_MAGICS = frozenset(bytes.fromhex(value) for value in (
    'cffaedfe', 'feedfacf', 'cefaedfe', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca',
))
CAMERA_CLASSES = frozenset({
    'AVCaptureDevice',
    'AVCaptureDeviceDiscoverySession',
    'AVCaptureDeviceInput',
    'AVCaptureDeviceRotationCoordinator',
    'AVCaptureMetadataOutput',
    'AVCaptureMovieFileOutput',
    'AVCaptureMultiCamSession',
    'AVCapturePhotoOutput',
    'AVCaptureSession',
    'AVCaptureVideoDataOutput',
    'AVCaptureVideoPreviewLayer',
})
CLASS_IMPORT = re.compile(rb'(?<!\S)_OBJC_(?:META)?CLASS_\$_([A-Za-z_][A-Za-z_0-9]*)(?=\s|$)')
CAMERA_PURPOSE = 'NSCameraUsageDescription'


def read_plist(path: Path) -> dict[str, object]:
    with path.open('rb') as source:
        value = plistlib.load(source)
    if not isinstance(value, dict):
        raise TypeError('Expected a bundle Info.plist dictionary')
    return value


def is_macho(path: Path) -> bool:
    with path.open('rb') as binary:
        return binary.read(4) in MACHO_MAGICS


def imported_symbols(path: Path) -> bytes:
    return subprocess.run(
        ['/usr/bin/xcrun', 'nm', '-u', '-arch', 'all', str(path)],
        check=True, capture_output=True, timeout=60,
    ).stdout


def release_app(artifact: Path) -> Path:
    artifact = artifact.resolve(strict=True)
    if artifact.suffix == '.xcarchive':
        app = (artifact / 'Products' / APP_PATH).resolve(strict=True)
        if not app.is_relative_to(artifact) or list(app.parent.glob('*.app')) != [app]:
            raise ValueError('Expected one RideCom App in the archive')
    elif artifact.suffix == '.app':
        app = artifact
    else:
        raise ValueError('Expected an Xcode archive or exported App bundle')
    info_path = (app / 'Info.plist').resolve(strict=True)
    if not info_path.is_relative_to(app):
        raise ValueError('Info.plist must be part of the App bundle')
    info = read_plist(info_path)
    if (info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']
            or info.get('StorageNamespace') != 'RideIntercom'):
        raise ValueError('Expected the RideCom iOS Release bundle')
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError('Missing App executable name')
    binary = (app / executable).resolve(strict=True)
    if not binary.is_relative_to(app) or not is_macho(binary):
        raise ValueError('Missing Mach-O App executable')
    check_signature(app)
    return app


def raise_read_error(error: OSError) -> None:
    raise error


def extract_ipa_app(ipa: Path, directory: Path) -> Path:
    names = set()
    with zipfile.ZipFile(ipa) as package:
        for member in package.infolist():
            name = member.filename.removesuffix('/')
            parts = name.split('/')
            if parts[0] != 'Payload':
                continue
            mode = member.external_attr >> 16
            expected = stat.S_IFDIR if member.is_dir() else stat.S_IFREG
            if (any(part in ('', '.', '..') for part in parts) or '\\' in name
                    or member.orig_filename != member.filename or stat.S_IFMT(mode) not in (0, expected)):
                raise ValueError('Invalid member in the IPA payload')
            key = unicodedata.normalize('NFD', name).casefold()
            if key in names:
                raise ValueError('Duplicate member in the IPA payload')
            names.add(key)
            target = Path(package.extract(member, directory))
            if not member.is_dir() and stat.S_IMODE(mode):
                target.chmod(mode & 0o777)
    app = directory / 'Payload' / Path(APP_PATH).name
    if list(app.parent.glob('*.app')) != [app]:
        raise ValueError('Expected only the RideCom App in the IPA payload')
    return app


def inspect(artifact: Path) -> list[tuple[str, tuple[str, ...]]]:
    if artifact.suffix == '.ipa':
        with tempfile.TemporaryDirectory(prefix='ridecom-release-') as temporary:
            return inspect(extract_ipa_app(artifact, Path(temporary)))
    app = release_app(artifact)
    findings = []
    for folder, directories, files in os.walk(app, onerror=raise_read_error):
        for name in directories + files:
            path = Path(folder) / name
            if path.is_symlink():
                if not path.resolve(strict=True).is_relative_to(app):
                    raise ValueError('Bundle has a reference outside the artifact')
                continue
            if not path.is_file():
                continue
            if path.name == 'Info.plist' and CAMERA_PURPOSE in read_plist(path):
                findings.append((path.relative_to(app).as_posix(), (CAMERA_PURPOSE,)))
            if is_macho(path):
                imports = {name.decode('ascii') for name in CLASS_IMPORT.findall(imported_symbols(path))}
                if matches := CAMERA_CLASSES & imports:
                    findings.append((path.relative_to(app).as_posix(), tuple(sorted(matches))))
    return sorted(findings)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', type=Path, help='Path to a signed iOS .xcarchive, .ipa, or exported RideIntercom.app')
    args = parser.parse_args(argv)
    try:
        findings = inspect(args.artifact)
    except (OSError, ValueError, TypeError, RuntimeError, plistlib.InvalidFileException,
            subprocess.SubprocessError, zipfile.BadZipFile):
        print('Camera inspection incomplete. Select an intact, signed RideCom iOS Release artifact.', file=sys.stderr)
        return 2
    for component, matches in findings:
        print(f'{component}: {", ".join(matches)}', file=sys.stderr)
    if findings:
        print('Camera references found in the release artifact.', file=sys.stderr)
        return 1
    print('Camera inspection passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
