"""Link a RideCom C++ adapter against the unmodified WebRTC modular factory."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

from webrtc_modular_link_inputs import CAMERA_COMPONENTS, modular_link_inputs

FACTORY_TARGET = '//api:create_modular_peer_connection_factory'


def require_unmodified_source(source: Path) -> None:
    clean = subprocess.run(['git', 'diff', '--quiet', '--no-ext-diff', 'HEAD'], cwd=source, check=False)
    if clean.returncode != 0:
        raise ValueError('WebRTC checkout must have unmodified tracked source')


def build_library(
    source: Path, build: Path, adapter: Path, library: Path, *,
    install_name: str | None = None, debug_symbols: Path | None = None,
) -> None:
    # A generated build directory supplies the stock compiler settings and ABI.
    gn = source / 'buildtools/mac/gn'
    ninja = str(source / 'third_party/ninja/ninja')
    clang = source / 'third_party/llvm-build/Release+Asserts/bin/clang++'
    require_unmodified_source(source)
    description = subprocess.check_output(
        [gn, 'desc', build, FACTORY_TARGET, f'--root={source}', '--format=json'],
        cwd=source, text=True,
    )
    factory = json.loads(description)[FACTORY_TARGET]

    inputs = modular_link_inputs(ninja, build)
    targets = [item for item in inputs if item.startswith('obj/')]
    commands = subprocess.check_output([ninja, '-t', 'commands', *targets], cwd=build, text=True).lower()
    if any(component in commands for component in CAMERA_COMPONENTS):
        raise ValueError('Camera or full WebRTC framework dependency in build commands')
    subprocess.run([ninja, *targets], cwd=build, check=True)

    includes = [source / path[2:] if path.startswith('//') else Path(path) for path in factory['include_dirs']]
    compile_flags = [
        *factory['cflags'], *factory['cflags_cc'],
        *(f'-D{define}' for define in factory['defines']),
        *(f'-I{os.path.relpath(path, build)}' for path in includes),
    ]
    # -Wcrl is interpreted by GN's link wrapper, which this direct link does not use.
    link_flags = [flag for flag in factory['ldflags'] if not flag.startswith('-Wcrl,')]
    frameworks = [flag for item in factory['frameworks'] for flag in ('-framework', Path(item).stem)]
    library.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=library.parent) as temporary:
        object_file = Path(temporary) / 'adapter.o'
        candidate = Path(temporary) / library.name
        subprocess.run([
            clang, *compile_flags, '-c', os.path.relpath(adapter, build), '-o', object_file,
        ], cwd=build, check=True)
        subprocess.run([
            clang, *link_flags, '-fuse-ld=lld', '-dynamiclib', '-Xlinker', '-install_name',
            '-Xlinker', install_name or f'@rpath/{library.name}',
            object_file, *inputs, *frameworks, '-o', candidate,
        ], cwd=build, check=True)
        symbols = subprocess.check_output(['nm', '-u', '-arch', 'all', candidate], text=True)
        if any(f'_OBJC_{kind}_$_AVCapture' in symbols for kind in ('CLASS', 'METACLASS')):
            raise ValueError('Camera class reference in linked library')
        if debug_symbols is not None:
            bundle = Path(temporary) / debug_symbols.name
            subprocess.run(['xcrun', 'dsymutil', candidate, '-o', bundle], cwd=build, check=True)
            bundle.rename(debug_symbols)
        candidate.replace(library)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Unmodified WebRTC source checkout')
    parser.add_argument('build', type=Path, help='GN-generated Apple platform output directory')
    parser.add_argument('adapter', type=Path, help='RideCom C++ source exposing the adapter entry points')
    parser.add_argument('library', type=Path, help='Output dynamic library')
    options = parser.parse_args()
    if not options.adapter.is_file() or options.library.suffix != '.dylib':
        parser.error('an adapter source file and a .dylib output are required')
    try:
        build_library(
            options.source.resolve(), options.build.resolve(), options.adapter.resolve(), options.library.absolute(),
        )
    except (OSError, KeyError, subprocess.CalledProcessError):
        parser.exit(1, 'Could not build the WebRTC modular library.\n')
    except ValueError as error:
        parser.exit(1, f'{error}.\n')


if __name__ == '__main__':
    main()
