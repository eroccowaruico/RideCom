"""Publish the fixed WebRTC zip/metadata pair with one macOS directory exchange."""

from __future__ import annotations

import ctypes
import errno
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from webrtc_provenance import file_sha256, read_provenance

RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
ZIP_NAME = 'WebRTC.xcframework.zip'
METADATA_NAME = 'WebRTC.xcframework.metadata'


def _rename_directory(source: Path, destination: Path, flags: int) -> None:
    if sys.platform != 'darwin':
        raise OSError(errno.ENOTSUP, 'Atomic artifact publication requires macOS')
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), flags) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def _write_metadata(path: Path, source_name: str, checksum: str, provenance: dict[str, object]) -> None:
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    with path.open('w') as stream:
        stream.write(f'source_zip={source_name}\nchecksum={checksum}\nimported_at={timestamp}\n')
        stream.write('build_provenance=' + json.dumps(provenance, separators=(',', ':'), sort_keys=True) + '\n')
        stream.flush()
        os.fsync(stream.fileno())


def _validate_destination(destination: Path) -> None:
    # Replacing this directory must not discard an unrelated user file or follow
    # an artifact-directory symlink. Only the existing pair belongs to this tool.
    if destination.is_symlink():
        raise OSError(errno.ELOOP, 'Artifact directory must not be a symbolic link', str(destination))
    if destination.exists():
        unexpected = {path.name for path in destination.iterdir()} - {ZIP_NAME, METADATA_NAME}
        if unexpected:
            raise ValueError('Artifact directory contains unrelated files; existing contents were preserved')


def _verify_debug_symbol_paths(artifact: Path) -> None:
    user_home = re.compile(rb'/(?:Users/(?!Shared/)|home/)[^/\x00\r\n]+/')
    with zipfile.ZipFile(artifact) as archive:
        for member in archive.infolist():
            if member.is_dir() or '.dSYM/Contents/Resources/DWARF/' not in member.filename:
                continue
            if user_home.search(archive.read(member)):
                raise ValueError('WebRTC debug symbols contain a user home path. '
                                 'Build with WEBRTC_BUILD_ROOT outside user home directories.')


def _cleanup_owned_pair(staging: Path) -> None:
    if not os.path.lexists(staging):
        return
    if not staging.is_symlink():
        for name in (ZIP_NAME, METADATA_NAME):
            try:
                (staging / name).unlink()
            except (FileNotFoundError, IsADirectoryError):
                pass
        try:
            staging.rmdir()
            return
        except OSError as error:
            if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                raise
    print(f'Unrelated staging contents were preserved at: {staging}', file=sys.stderr)


def import_artifact(source: str | Path, destination: str | Path, verifier: str | Path) -> str:
    source, destination, verifier = Path(source), Path(destination), Path(verifier)
    _validate_destination(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A sibling ensures the publication operation never crosses filesystems.
    # On exchange this owned staging path receives the previous directory.
    staging = Path(tempfile.mkdtemp(prefix=f'.{destination.name}.import-', dir=destination.parent))
    try:
        staged_zip = staging / ZIP_NAME
        subprocess.run(['cp', str(source), str(staged_zip)], check=True)
        with staged_zip.open('rb+') as stream:
            os.fsync(stream.fileno())
        # Validate the copied bytes, not a source that may change before copying.
        with tempfile.TemporaryDirectory(prefix='WebRTC-verify-') as unpacked:
            subprocess.run(['unzip', '-q', str(staged_zip), '-d', unpacked], check=True)
            subprocess.run([str(verifier), str(Path(unpacked) / 'WebRTC.xcframework')], check=True)
        _verify_debug_symbol_paths(staged_zip)
        checksum = file_sha256(staged_zip)
        provenance = read_provenance(source, checksum)
        _write_metadata(staging / METADATA_NAME, source.name, checksum, provenance)
        # No delete/move fallback: unsupported filesystems leave the old pair in
        # place. An initial publication must not replace a concurrent install.
        _validate_destination(destination)
        flags = RENAME_SWAP if destination.exists() else RENAME_EXCL
        _rename_directory(staging, destination, flags)
    finally:
        _cleanup_owned_pair(staging)
    return checksum


def main() -> None:
    if len(sys.argv) != 4:
        raise ValueError('Expected source zip, artifact directory and verifier')
    checksum = import_artifact(*map(Path, sys.argv[1:]))
    print(f'Imported: {Path(sys.argv[2]) / ZIP_NAME}')
    print(f'Checksum: {checksum}')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'WebRTC artifact import failed: {error}', file=sys.stderr)
        sys.exit(1)
