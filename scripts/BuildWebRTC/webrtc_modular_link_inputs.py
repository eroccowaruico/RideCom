"""List the link inputs of the official WebRTC modular C++ factory.

Read a GN-generated Ninja directory without compiling or invoking its default
target. Output paths are relative to that directory, in linker argument order.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
from pathlib import Path

ROOT_ARCHIVES = (
    'obj/api/libcreate_modular_peer_connection_factory.a',
    'obj/buildtools/third_party/libc++/libc++.a',
    'obj/buildtools/third_party/libc++abi/libc++abi.a',
)
CAMERA_COMPONENTS = (
    'avcapturesession', 'rtccameravideocapturer', 'videocapture_objc', 'video_capture',
    'framework_objc_shared_library',
)


def query_inputs(ninja: str, build: Path, targets: list[str]) -> dict[str, list[str]]:
    output = subprocess.check_output(
        [ninja, '-t', 'query', *targets], cwd=build, text=True, stderr=subprocess.DEVNULL,
    )
    graph: dict[str, list[str]] = {}
    recording = False
    for line in output.splitlines():
        if not line.startswith(' ') and line.endswith(':'):
            target = line[:-1]
            graph[target] = []
            recording = False
        elif line.startswith('  input:'):
            recording = True
        elif line == '  outputs:':
            recording = False
        elif recording and line.startswith('    '):
            graph[target].append(line.strip())
    if graph.keys() != set(targets):
        raise ValueError('Unexpected Ninja query output')
    return graph


def modular_link_inputs(ninja: str, build: Path) -> list[str]:
    archives = dict.fromkeys(ROOT_ARCHIVES)
    objects: dict[str, None] = {}
    visited: set[str] = set()
    pending = list(ROOT_ARCHIVES)
    while pending:
        visited.update(pending)
        next_targets = []
        for target, inputs in query_inputs(ninja, build, pending).items():
            for entry in inputs:
                artifact = entry.removeprefix('|| ').removeprefix('| ')
                if any(component in artifact.lower() for component in CAMERA_COMPONENTS):
                    raise ValueError('Camera or full WebRTC framework dependency in modular target')
                # Archive member objects are already represented by the archive.
                if entry.startswith('|| ') and artifact.endswith(('.linkdeps', '.a', '.rlib')):
                    next_targets.append(artifact)
                    if not artifact.endswith('.linkdeps'):
                        archives[artifact] = None
                elif entry.startswith('| ') and artifact.endswith('.a'):
                    archives[artifact] = None
                elif target.endswith('.linkdeps') and artifact.endswith('.o'):
                    objects[artifact] = None
        pending = sorted(set(next_targets) - visited)

    # Standalone objects may reference symbols supplied by the archives.
    # Keep the factory first and the remaining archives in discovery order.
    return [*ROOT_ARCHIVES, *objects, *(archive for archive in archives if archive not in ROOT_ARCHIVES)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('build_directory', type=Path, help='GN-generated Ninja directory')
    parser.add_argument('--ninja', default='ninja', help='Ninja executable')
    options = parser.parse_args()
    executable = shutil.which(options.ninja)
    if executable is None:
        parser.exit(1, 'Ninja executable is unavailable.\n')
    try:
        inputs = modular_link_inputs(str(Path(executable).resolve()), options.build_directory)
    except (OSError, subprocess.CalledProcessError):
        parser.exit(1, 'Could not read the official WebRTC modular targets.\n')
    except ValueError as error:
        parser.exit(1, f'{error}.\n')
    print('\n'.join(inputs))


if __name__ == '__main__':
    main()
