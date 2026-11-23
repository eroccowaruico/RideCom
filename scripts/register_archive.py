"""Place an existing signed RideCom release archive in Xcode's local Archives."""
import argparse
import ctypes
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from datetime import date, datetime, timezone
from pathlib import Path

BUNDLE_ID = 'com.yowamushi-inc.RideIntercom.RideIntercom'
APP_PATH = 'Applications/RideIntercom.app'
RENAME_EXCL = 0x00000004  # Darwin stdio.h


def check_signature(product: Path) -> None:
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=2', product], check=True, capture_output=True)
    if not re.search(rb'^Authority=.+$', signature.stderr, re.MULTILINE):
        raise ValueError('Archive must have a certificate signature')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', product], check=True)


def macho_uuids(file: Path) -> set[tuple[bytes, bytes]]:
    output = subprocess.check_output(['/usr/bin/xcrun', 'dwarfdump', '--uuid', file])
    return set(re.findall(rb'^UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)', output, re.MULTILINE))


def check_symbols(archive_root: Path, binary: Path, symbols: Path, component: str) -> None:
    if any(not path.is_file() or not path.resolve().is_relative_to(archive_root) for path in (binary, symbols)):
        raise ValueError(f'Archive must contain the {component} executable and its dSYM')
    executable_uuids = macho_uuids(binary)
    if not executable_uuids or executable_uuids != macho_uuids(symbols):
        raise ValueError(f'Archive {component} dSYM UUIDs must match the executable')


def archive_info(archive: Path) -> tuple[date, str, str, str]:
    if archive.suffix != '.xcarchive' or not archive.is_dir():
        raise ValueError('Select a RideIntercom .xcarchive directory')
    with (archive / 'Info.plist').open('rb') as info:
        metadata = plistlib.load(info)
    properties = metadata['ApplicationProperties']
    product = archive / 'Products' / APP_PATH
    archive_root = archive.resolve()
    if (properties.get('ApplicationPath') != APP_PATH
            or list(product.parent.glob('*.app')) != [product]
            or not product.is_dir() or not product.resolve().is_relative_to(archive_root)):
        raise ValueError('Archive must contain one top-level RideIntercom App')

    contents = product / 'Contents' if (product / 'Contents').is_dir() else product
    with (contents / 'Info.plist').open('rb') as info:
        bundle = plistlib.load(info)
    if bundle.get('StorageNamespace') != 'RideIntercom':
        raise ValueError('Archive must use the standard Release storage namespace')
    if (bundle.get('CFBundleIdentifier') != BUNDLE_ID
            or any(properties.get(key) != bundle.get(key) for key in
                   ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'))):
        raise ValueError('Archive and App metadata must identify the same RideIntercom version and build')
    platforms = bundle.get('CFBundleSupportedPlatforms')
    if platforms == ['iPhoneOS']:
        platform_name = 'iOS'
        if any((product / 'Watch').glob('*.app')):
            raise ValueError('The standard iOS Release must exclude the Watch App')
    elif platforms == ['MacOSX']:
        platform_name = 'Mac'
    else:
        raise ValueError('Archive must target iPhone devices or Mac')

    version, build = bundle['CFBundleShortVersionString'], bundle['CFBundleVersion']
    if not all(isinstance(value, str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', value)
               for value in (version, build)):
        raise ValueError('Archive version and build must be Xcode version numbers')
    created = metadata['CreationDate']
    if not isinstance(created, datetime) or bundle.get('CFBundleExecutable') != 'RideIntercom':
        raise ValueError('Archive requires a creation date and the RideIntercom executable')
    if not properties.get('SigningIdentity'):
        raise ValueError('Archive must contain a signing identity')
    binary = contents / ('MacOS/RideIntercom' if contents != product else 'RideIntercom')
    symbols = archive / 'dSYMs/RideIntercom.app.dSYM/Contents/Resources/DWARF/RideIntercom'
    check_signature(product)
    check_symbols(archive_root, binary, symbols, 'App')
    if platform_name == 'iOS':
        web_rtc = product / 'Frameworks/WebRTC.framework/WebRTC'
        web_rtc_symbols = archive / 'dSYMs/WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC'
        check_symbols(archive_root, web_rtc, web_rtc_symbols, 'WebRTC')
    archive_date = created.replace(tzinfo=created.tzinfo or timezone.utc).astimezone().date()
    return archive_date, platform_name, version, build


def publish_archive(staged: Path, destination: Path) -> None:
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staged), os.fsencode(destination), RENAME_EXCL) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), destination)


def register(source: Path, archives: Path) -> Path:
    source = source.resolve(strict=True)
    day, platform_name, version, build = archive_info(source)
    archives = archives.resolve()
    if source.parent.parent == archives and re.fullmatch(r'\d{4}-\d{2}-\d{2}', source.parent.name):
        return source
    directory = archives / day.isoformat()
    if directory.is_symlink():
        raise ValueError('Archive date directory must be inside Xcode Archives')
    destination = directory / f'RideIntercom {platform_name} {version} ({build}).xcarchive'
    if os.path.lexists(destination):
        raise FileExistsError(f'Archive already exists: {destination}')
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.rideintercom-import-', dir=directory) as temporary:
        staged = Path(temporary) / destination.name
        subprocess.run(['/usr/bin/ditto', source, staged], check=True)
        if archive_info(staged) != (day, platform_name, version, build):
            raise ValueError('Copied archive metadata changed')
        publish_archive(staged, destination)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, help='Path to an existing signed RideIntercom .xcarchive')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Xcode Archives registration requires macOS')
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    try:
        destination = register(args.archive, Path.home() / 'Library/Developer/Xcode/Archives')
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.CalledProcessError) as error:
        print(f'Archive registration failed: {error}', file=sys.stderr)
        return 1
    print(destination)
    return 0


if __name__ == '__main__':
    sys.exit(main())
