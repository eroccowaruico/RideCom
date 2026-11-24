"""Exercise the modular WebRTC link inputs with a small Ninja graph."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'BuildWebRTC/webrtc_modular_link_inputs.py'

FACTORY = 'obj/api/libcreate_modular_peer_connection_factory.a'
LINK_DEPS = 'phony/api/modular.linkdeps'
NINJA_INPUTS = {
    FACTORY: ['obj/api/factory.o', '| ../../native/libclang_rt.a', f'|| {LINK_DEPS}'],
    LINK_DEPS: ['obj/api/adapter.o', '|| obj/api/libdata_channel.a', '|| phony/api/wrapper.linkdeps'],
    'phony/api/wrapper.linkdeps': ['|| obj/api/libdata_channel.a'],
    'obj/api/libdata_channel.a': ['obj/api/data_channel.o'],
    'obj/buildtools/third_party/libc++/libc++.a': [],
    'obj/buildtools/third_party/libc++abi/libc++abi.a': [],
    'obj/sdk/WebRTC': ['obj/sdk/RTCCameraVideoCapturer.o'],
}
FAKE_NINJA = """
import json
import sys
from pathlib import Path

if sys.argv[1:3] != ['-t', 'query']:
    sys.exit(2)
graph = json.loads(Path('inputs.json').read_text())
for target in sys.argv[3:]:
    if target not in graph:
        sys.exit(1)
    print(target + ':')
    print('  input: fixture')
    for source in graph[target]:
        print('    ' + source)
    print('  outputs:')
    print('    obj/sdk/WebRTC')
"""


class WebRTCModularLinkInputsTests(unittest.TestCase):
    def invoke(self, manifest: dict[str, list[str]]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            (build / 'inputs.json').write_text(json.dumps(manifest))
            ninja = build / 'ninja'
            ninja.write_text(f'#!{sys.executable}\n' + FAKE_NINJA)
            ninja.chmod(0o755)
            return subprocess.run([sys.executable, str(SCRIPT), str(build), '--ninja', str(ninja)],
                                  capture_output=True, text=True, check=False)

    def test_returns_only_artifacts_needed_to_link_the_modular_factory(self) -> None:
        result = self.invoke(NINJA_INPUTS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            FACTORY,
            'obj/buildtools/third_party/libc++/libc++.a',
            'obj/buildtools/third_party/libc++abi/libc++abi.a',
            'obj/api/adapter.o',
            '../../native/libclang_rt.a',
            'obj/api/libdata_channel.a',
        ])

    def test_stops_if_the_factory_starts_linking_the_camera_implementation(self) -> None:
        changed = NINJA_INPUTS | {LINK_DEPS: ['obj/sdk/RTCCameraVideoCapturer.o']}
        result = self.invoke(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Camera', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_stops_if_the_official_factory_target_is_unavailable(self) -> None:
        changed = {target: inputs for target, inputs in NINJA_INPUTS.items() if target != FACTORY}
        result = self.invoke(changed)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
