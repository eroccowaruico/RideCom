"""Protect an existing artifact when the newly linked library fails its check."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from importlib import import_module
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'BuildWebRTC'))
builder = import_module('build_webrtc_modular_library')
sys.path.pop(0)


class WebRTCModularLibraryTests(unittest.TestCase):
    def test_camera_reference_does_not_replace_existing_library(self) -> None:
        configuration = json.dumps({
            builder.FACTORY_TARGET: {
                'cflags': [], 'cflags_cc': [], 'include_dirs': [], 'defines': [],
                'ldflags': [], 'frameworks': [],
            },
        })
        archives = ['obj/api/libcreate_modular_peer_connection_factory.a']

        def run(command: list[str | Path], **_: object) -> subprocess.CompletedProcess[object]:
            if '-dynamiclib' in command:
                Path(command[-1]).write_bytes(b'unsafe candidate')
            return subprocess.CompletedProcess(command, 0)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / 'libWebRTCProbe.dylib'
            library.write_bytes(b'previously verified library')
            with (
                patch.object(builder, 'modular_link_inputs', return_value=archives),
                patch.object(builder.subprocess, 'run', side_effect=run),
                patch.object(builder.subprocess, 'check_output', side_effect=[
                    configuration, 'fixture compiler command', '                 U _OBJC_CLASS_$_AVCaptureSession',
                ]),
                self.assertRaisesRegex(ValueError, 'Camera class reference'),
            ):
                builder.build_library(root, root, root / 'adapter.cc', library)
            self.assertEqual(library.read_bytes(), b'previously verified library')
            self.assertEqual(list(root.iterdir()), [library])
