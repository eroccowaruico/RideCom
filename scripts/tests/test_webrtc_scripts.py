"""Regression checks for artifact validation and failed-update preservation."""
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / 'scripts/BuildWebRTC'
ARTIFACT = ROOT / 'RideIntercom/packages/RTC/BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'


class WebRTCScriptTests(unittest.TestCase):
    def test_doctor_requires_zip_to_match_adoption_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/BuildWebRTC'
            scripts.mkdir(parents=True)
            for name in ('doctor-webrtc-binary.sh', 'webrtc_provenance.py', 'webrtc-build-root.sh'):
                shutil.copy2(SCRIPTS / name, scripts)
            resolver = scripts / 'resolve-webrtc-branch.sh'
            resolver.write_text('#!/bin/sh\nexit 1\n')
            resolver.chmod(0o755)
            developer = root / 'developer'
            (developer / 'usr/bin').mkdir(parents=True)
            (developer / 'usr/bin/xcodebuild').touch()
            for name in ('gclient', 'fetch'):
                (root / name).touch()
            artifact = root / ARTIFACT.relative_to(ROOT)
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b'adopted SDK fixture')
            checksum = hashlib.sha256(artifact.read_bytes()).hexdigest()
            metadata = artifact.with_suffix('.metadata')
            environment = dict(os.environ, DEVELOPER_DIR=str(developer), DEPOT_TOOLS_DIR=str(root),
                               WEBRTC_BUILD_ROOT=str(root / 'build'), RUN_SWIFTPM_CHECK='false')
            records = {
                'match': (f'checksum={checksum}\n', 0),
                'mismatch': ('checksum=' + '0' * 64, 1),
                'duplicate': (f'checksum={checksum}\nchecksum={checksum}\n', 1),
                'empty': ('', 1),
                'missing': (None, 1),
            }
            for case, (record, expected) in records.items():
                with self.subTest(case=case):
                    if record is None:
                        metadata.unlink(missing_ok=True)
                    else:
                        metadata.write_text(record)
                    result = subprocess.run([str(scripts / 'doctor-webrtc-binary.sh')], env=environment,
                                            capture_output=True, text=True, check=False)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_xcframework_build_defaults_match_supported_os_floor(self) -> None:
        script = (SCRIPTS / 'build-webrtc-xcframework.sh').read_text()
        self.assertIn('IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-27.0}"', script)
        self.assertIn('MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-27.0}"', script)

    def test_generation_uses_the_official_revision_and_rejects_a_modified_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            upstream = root / 'upstream'
            subprocess.run(['git', 'init', '-q', str(upstream)], check=True)
            (upstream / 'BUILD.gn').write_text('# upstream fixture')
            subprocess.run(['git', 'add', 'BUILD.gn'], cwd=upstream, check=True)
            subprocess.run(['git', '-c', 'user.name=Test', '-c', 'user.email=fixture@localhost',
                            'commit', '-qm', 'fixture'], cwd=upstream, check=True)
            revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=upstream, text=True).strip()
            depot = root / 'tools'
            subprocess.run(['git', 'clone', '-q', str(upstream), str(depot)], check=True)
            for name, body in {
                'fetch': 'exit 99',
                'gclient': 'if [ "$1" = sync ]; then\n'
                           '  if [ "$DIRTY_SOURCE" = yes ]; then echo changed >> src/BUILD.gn; fi\n'
                           'else\n  shift 3; "$@" || exit $?\nfi',
                'gn': 'git diff --exit-code HEAD -- && touch "$GEN_REACHED"; exit 77',
            }.items():
                tool = depot / name
                tool.write_text('#!/bin/sh\n' + body + '\n')
                tool.chmod(0o755)
            for dirty in ('no', 'yes'):
                with self.subTest(dirty=dirty):
                    build = root / dirty
                    subprocess.run(['git', 'clone', '-q', str(upstream), str(build / 'src')], check=True)
                    marker = build / 'generation-started'
                    environment = dict(os.environ, WEBRTC_BUILD_ROOT=str(build), DEPOT_TOOLS_DIR=str(depot),
                                       WEBRTC_BRANCH=revision, DIRTY_SOURCE=dirty, GEN_REACHED=str(marker),
                                       GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f'url.{upstream}.insteadOf',
                                       GIT_CONFIG_VALUE_0='https://webrtc.googlesource.com/src',
                                       PATH=str(depot) + os.pathsep + os.environ['PATH'])
                    result = subprocess.run([str(SCRIPTS / 'build-webrtc-xcframework.sh')],
                                            env=environment, capture_output=True, text=True, check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(marker.exists(), dirty == 'no', result.stderr)

    def test_adopted_framework_rejects_a_camera_symbol(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['unzip', '-q', str(ARTIFACT), '-d', directory], check=True)
            commands = root / 'bin'
            commands.mkdir()
            nm = commands / 'nm'
            nm.write_text(
                "#!/bin/sh\nprintf '%s\\n' '0001 T _RideComRTCFactoryCreate' '_OBJC_CLASS_$_AVCaptureSession'\n"
            )
            nm.chmod(0o755)
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'),
                                     str(root / 'WebRTC.xcframework')],
                                    env=dict(os.environ, PATH=str(commands) + os.pathsep + os.environ['PATH']),
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('Camera API present in modular SDK', result.stderr)

    def test_cleanup_rejects_non_checkout_without_removing_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sentinel = root / 'important.txt'
            sentinel.write_text('preserve')
            result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                    env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                             CLEAN_MODE='source', DRY_RUN='false'), capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), 'preserve')

    def test_cleanup_only_removes_verified_checkout_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'webrtc-build'
            (root / 'src/out').mkdir(parents=True)
            (root / 'src/.git').mkdir()
            (root / '.gclient').write_text('fixture')
            (root / 'src/BUILD.gn').write_text('fixture')
            (root / 'src/out/generated').write_text('remove')
            result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                    env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                             CLEAN_MODE='build-output', DRY_RUN='false'), capture_output=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / 'src/out').exists())
            self.assertTrue((root / 'src/BUILD.gn').exists())

    def test_cleanup_rejects_symlink_escape_and_misspelled_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'webrtc-build'
            (root / 'src/.git').mkdir(parents=True)
            (root / '.gclient').write_text('fixture')
            (root / 'src/BUILD.gn').write_text('fixture')
            other = Path(directory) / 'important'
            other.mkdir()
            sentinel = other / 'keep'
            sentinel.touch()
            (root / 'src/out').symlink_to(other, target_is_directory=True)
            for mode, dry in [('build-output', 'false'), ('source', 'flase')]:
                if mode == 'source':
                    (root / 'src/out').unlink()
                    (root / 'src/out').mkdir()
                result = subprocess.run([str(SCRIPTS / 'clean-webrtc-build-resources.sh')],
                                        env=dict(os.environ, WEBRTC_BUILD_ROOT=str(root),
                                                 CLEAN_MODE=mode, DRY_RUN=dry), capture_output=True, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(sentinel.exists())
                self.assertTrue((root / 'src/BUILD.gn').exists())

    def test_empty_xcframework_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), directory], capture_output=True, check=False)
            self.assertNotEqual(result.returncode, 0, result.stdout.decode())

    def test_distribution_slice_without_symbols_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['unzip', '-q', str(ARTIFACT), '-d', directory], check=True)
            root = Path(directory) / 'WebRTC.xcframework'
            manifest_path = root / 'Info.plist'
            manifest = plistlib.loads(manifest_path.read_bytes())
            device = next(item for item in manifest['AvailableLibraries']
                          if item['SupportedPlatform'] == 'ios'
                          and not item.get('SupportedPlatformVariant'))
            device.pop('DebugSymbolsPath', None)
            manifest_path.write_bytes(plistlib.dumps(manifest))
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), str(root)],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing dSYM', result.stderr)

    def test_missing_or_mismatched_dsym_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run(['unzip', '-q', str(ARTIFACT), '-d', directory], check=True)
            root = Path(directory) / 'WebRTC.xcframework'
            manifest = plistlib.loads((root / 'Info.plist').read_bytes())
            device = next(item for item in manifest['AvailableLibraries']
                          if item['SupportedPlatform'] == 'ios'
                          and not item.get('SupportedPlatformVariant'))
            dwarf = (root / device['LibraryIdentifier'] / device['DebugSymbolsPath']
                     / 'WebRTC.framework.dSYM/Contents/Resources/DWARF/WebRTC')
            dwarf.unlink()
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), str(root)],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing dSYM', result.stderr)
            # Use a real Mach-O from another slice, so a file-existence check cannot pass.
            mac = next(item for item in manifest['AvailableLibraries']
                       if item['SupportedPlatform'] == 'macos')
            shutil.copyfile(root / mac['LibraryIdentifier'] / mac['LibraryPath'] / 'WebRTC', dwarf)
            result = subprocess.run([str(SCRIPTS / 'verify-webrtc-xcframework.sh'), str(root)],
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('dSYM UUID mismatch', result.stderr)

    def test_failed_native_validation_keeps_installed_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / 'scripts/BuildWebRTC'
            shutil.copytree(SCRIPTS, scripts)
            package = root / 'RideIntercom/packages/RTC'
            shutil.copytree(ROOT / 'RideIntercom/packages/RTC', package,
                            ignore=shutil.ignore_patterns('.build', '.swiftpm', '.git'))
            artifact = package / 'BinaryArtifacts/WebRTC/WebRTC.xcframework.zip'
            artifact.write_bytes(b'previous artifact must survive')
            metadata = artifact.with_suffix('.metadata')
            before_metadata = metadata.read_bytes()
            output = root / 'build/src/out'
            output.mkdir(parents=True)
            subprocess.run(['unzip', '-q', str(ARTIFACT), '-d', str(output)], check=True)
            candidate = output / 'WebRTC-branch-heads-test.xcframework.zip'
            shutil.copy(ARTIFACT, candidate)
            # Synthetic build record for the stub builder in this test.
            build_record = {
                'checksum': hashlib.sha256(candidate.read_bytes()).hexdigest(),
                'source_policy': 'official-unmodified',
                'upstream_revision': '1' * 40, 'depot_tools_revision': '2' * 40,
                'gn_version': '1234 (abcdef0)', 'xcode_version': '27.2', 'xcode_build': '27B52',
                'sdks': {'macosx': '27.2'},
                'gn_args_sha256': dict.fromkeys(('macos-arm64', 'macos-x64'), '3' * 64),
            }
            candidate.with_suffix('.provenance.json').write_text(json.dumps(build_record))
            (scripts / 'build-webrtc-xcframework.sh').write_text('#!/bin/bash\ntest "$ASSEMBLE_ONLY" = false\n')
            # A broken candidate package must fail compilation before installation.
            (package / 'Package.swift').write_text('// swift-tools-version: 6.3\ninvalid manifest\n')
            developer = Path(os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
            depot = root / 'depot_tools'
            depot.mkdir()
            for name in ['fetch', 'gclient']:
                (depot / name).touch(mode=0o755)
            environment = dict(os.environ, DEVELOPER_DIR=str(developer), DEPOT_TOOLS_DIR=str(depot),
                               WEBRTC_BUILD_ROOT=str(root / 'build'), RTC_PACKAGE_DIR=str(package),
                               WEBRTC_BRANCH='branch-heads/test', ASSEMBLE_ONLY='true',
                               RUN_SWIFTPM_VALIDATION='true', RUN_TESTS='true')
            result = subprocess.run([str(scripts / 'update-webrtc-binary.sh')], env=environment,
                                    capture_output=True, text=True, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Invalid manifest', result.stderr)
            self.assertEqual(artifact.stat().st_size, len(b'previous artifact must survive'))
            self.assertEqual(artifact.read_bytes(), b'previous artifact must survive')
            self.assertEqual(metadata.read_bytes(), before_metadata)


if __name__ == '__main__':
    unittest.main()
