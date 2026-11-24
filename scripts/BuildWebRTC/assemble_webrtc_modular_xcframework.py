"""Assemble the camera-free WebRTC candidate from prepared Apple GN directories."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from build_webrtc_modular_library import (
    FACTORY_TARGET,
    build_library,
    require_unmodified_source,
)
from webrtc_modular_link_inputs import CAMERA_COMPONENTS
from webrtc_provenance import PLATFORM_OUTPUTS

SCRIPT_DIR = Path(__file__).resolve().parent
ADAPTER = SCRIPT_DIR.parents[1] / 'RideIntercom/packages/RTC/BuildSupport/ModularWebRTC'


def copy_resources(source: Path, build: Path, *, mac: bool, destination: Path) -> None:
    target = 'mac_framework_objc' if mac else 'framework_objc'
    info = f'gen/sdk/{target}_info_plist.plist'
    privacy = f'gen/sdk/{target}/PrivacyInfo.xcprivacy'
    ninja = source / 'third_party/ninja/ninja'
    commands = subprocess.check_output([ninja, '-t', 'commands', info, privacy], cwd=build, text=True).lower()
    if any(component in commands for component in CAMERA_COMPONENTS):
        raise ValueError('Framework metadata would require a camera or full framework build')
    subprocess.run([ninja, info, privacy], cwd=build, check=True)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(build / info, destination / 'Info.plist')
    shutil.copyfile(build / privacy, destination / 'PrivacyInfo.xcprivacy')


def build_framework(
    source: Path, build_root: Path, stage: Path, sdk: str, adapter: Path,
) -> tuple[Path, Path | None]:
    directory = stage / sdk
    framework = directory / 'WebRTC.framework'
    mac = sdk == 'macosx'
    contents = framework / 'Versions/A' if mac else framework
    resources = contents / 'Resources' if mac else contents
    contents.mkdir(parents=True)
    debug_symbols = directory / 'WebRTC.framework.dSYM' if sdk == 'iphoneos' else None
    install_name = f'@rpath/WebRTC.framework/{"Versions/A/" if mac else ""}WebRTC'
    builds = [(build_root / name).resolve() for name in sorted(PLATFORM_OUTPUTS[sdk])]
    libraries = []
    for build in builds:
        library = directory / build.name / 'WebRTC'
        build_library(
            source, build, adapter / 'RideComRTC.cc', library,
            install_name=install_name, debug_symbols=debug_symbols,
        )
        libraries.append(library)
    binary = contents / 'WebRTC'
    subprocess.run(['xcrun', 'lipo', '-create', *libraries, '-output', binary], check=True)
    subprocess.run(['xcrun', 'strip', '-S', binary], check=True)

    copy_resources(source, builds[0], mac=mac, destination=resources)
    shutil.copyfile(stage / 'LICENSE.md', resources / 'LICENSE.md')
    headers = contents / 'Headers'
    headers.mkdir()
    shutil.copyfile(adapter / 'include/RideComRTC.h', headers / 'RideComRTC.h')
    (headers / 'WebRTC.h').write_text('#include "RideComRTC.h"\n')
    modules = contents / 'Modules'
    modules.mkdir()
    (modules / 'module.modulemap').write_text(
        'framework module WebRTC {\n    umbrella header "WebRTC.h"\n    export *\n}\n',
    )
    if mac:
        (framework / 'Versions/Current').symlink_to('A')
        for name in ('WebRTC', 'Headers', 'Modules', 'Resources'):
            (framework / name).symlink_to(f'Versions/Current/{name}')
    subprocess.run(['codesign', '--force', '--sign', '-', framework], check=True)
    return framework, debug_symbols


def assemble(source: Path, build_root: Path, output: Path) -> None:
    if output.exists() or output.is_symlink():
        raise ValueError('XCFramework output must be a new path')
    require_unmodified_source(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        stage = Path(temporary)
        adapter = stage / 'adapter'
        shutil.copytree(ADAPTER / 'include', adapter / 'include')
        shutil.copyfile(ADAPTER / 'RideComRTC.cc', adapter / 'RideComRTC.cc')
        builds = sorted((build_root / name).resolve() for names in PLATFORM_OUTPUTS.values() for name in names)
        subprocess.run([
            'python3', source / 'tools_webrtc/libs/generate_licenses.py',
            '--target', FACTORY_TARGET, stage, *builds,
        ], cwd=source, check=True)
        candidate = stage / 'WebRTC.xcframework'
        arguments: list[str | Path] = ['xcodebuild', '-create-xcframework']
        for sdk in PLATFORM_OUTPUTS:
            framework, debug_symbols = build_framework(source, build_root, stage, sdk, adapter)
            arguments.extend(['-framework', framework])
            if debug_symbols:
                arguments.extend(['-debug-symbols', debug_symbols])
        subprocess.run([*arguments, '-output', candidate], check=True)
        subprocess.run([SCRIPT_DIR / 'verify-webrtc-xcframework.sh', candidate, 'modular'], check=True)
        candidate.rename(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Unmodified WebRTC source checkout')
    parser.add_argument('build_root', type=Path, help='Directory containing the five Apple GN outputs')
    parser.add_argument('output', type=Path, help='New WebRTC.xcframework path')
    options = parser.parse_args()
    if options.output.name != 'WebRTC.xcframework':
        parser.error('output must be named WebRTC.xcframework')
    try:
        assemble(options.source.resolve(), options.build_root.resolve(), options.output.absolute())
    except (OSError, KeyError, subprocess.CalledProcessError):
        parser.exit(1, 'Could not assemble the modular WebRTC XCFramework.\n')
    except ValueError as error:
        parser.exit(1, f'{error}.\n')


if __name__ == '__main__':
    main()
