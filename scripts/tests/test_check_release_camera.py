import io
import plistlib
import stat
import subprocess
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts import check_release_camera


class CheckReleaseCameraTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.archive = Path(directory.name).resolve() / 'RideCom.xcarchive'
        self.app = self.archive / 'Products/Applications/RideIntercom.app'
        self.app.mkdir(parents=True)
        self.info = self.app / 'Info.plist'
        self.info.write_bytes(plistlib.dumps({
            'CFBundleIdentifier': check_release_camera.BUNDLE_ID,
            'CFBundleExecutable': 'RideIntercom',
            'CFBundleSupportedPlatforms': ['iPhoneOS'],
            'StorageNamespace': 'RideIntercom',
        }))
        self.binary = self.write_binary('RideIntercom')
        self.sdk = self.write_binary('Frameworks/WebRTC.framework/WebRTC')
        patcher = patch.object(check_release_camera, 'check_signature', autospec=True)
        self.verify = patcher.start()
        self.addCleanup(patcher.stop)

    def write_binary(self, name: str) -> Path:
        path = self.app / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(bytes.fromhex('cffaedfe'))
        return path

    def test_archive_checks_app_and_sdk_and_reports_exact_camera_imports(self) -> None:
        imports = {
            self.binary: b'_OBJC_CLASS_$_AVAudioEngine\n',
            self.sdk: b'_OBJC_CLASS_$_AVCaptureDeviceDiscoverySession\n_OBJC_CLASS_$_AVCaptureVideoDataOutput\n',
        }
        with patch.object(check_release_camera, 'imported_symbols', side_effect=imports.__getitem__) as symbols:
            findings = check_release_camera.inspect(self.archive)
        self.verify.assert_called_once_with(self.app)
        self.assertEqual({call.args[0] for call in symbols.call_args_list}, {self.binary, self.sdk})
        self.assertEqual(findings, [('Frameworks/WebRTC.framework/WebRTC', (
            'AVCaptureDeviceDiscoverySession', 'AVCaptureVideoDataOutput',
        ))])

    def test_app_allows_audio_and_non_camera_resources(self) -> None:
        (self.app / 'PublicDeclarations.h').write_text('AVCaptureVideoDataOutput')
        with patch.object(check_release_camera, 'imported_symbols', return_value=b'_OBJC_CLASS_$_AVAudioEngine\n'):
            self.assertEqual(check_release_camera.inspect(self.app), [])
        self.verify.assert_called_once_with(self.app)

    def test_an_embedded_bundle_with_a_camera_usage_description_is_reported(self) -> None:
        extension = self.app / 'PlugIns/Widget.appex'
        extension.mkdir(parents=True)
        (extension / 'Info.plist').write_bytes(plistlib.dumps({'NSCameraUsageDescription': 'Fixture'}))
        with patch.object(check_release_camera, 'imported_symbols', return_value=b''):
            self.assertEqual(check_release_camera.inspect(self.app), [
                ('PlugIns/Widget.appex/Info.plist', ('NSCameraUsageDescription',)),
            ])

    def test_unreadable_import_table_or_missing_binary_fails_the_command(self) -> None:
        with (patch.object(check_release_camera, 'imported_symbols',
                           side_effect=subprocess.CalledProcessError(1, ['nm'], stderr=b'private path')),
              redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as err):
            self.assertEqual(check_release_camera.main([str(self.archive)]), 2)
        self.assertNotIn('private path', err.getvalue())
        self.binary.unlink()
        with redirect_stderr(io.StringIO()):
            self.assertEqual(check_release_camera.main([str(self.archive)]), 2)

    def test_inspection_cannot_read_a_binary_outside_the_bundle(self) -> None:
        outside = self.archive.parent / 'DetachedBinary'
        self.binary.rename(outside)
        self.binary.symlink_to(outside)
        with redirect_stderr(io.StringIO()):
            self.assertEqual(check_release_camera.main([str(self.archive)]), 2)
        self.verify.assert_not_called()

    def make_ipa(self, path: Path) -> None:
        with zipfile.ZipFile(path, 'w') as package:
            for item in self.app.rglob('*'):
                if item.is_file():
                    package.write(item, (Path('Payload') / item.relative_to(self.app.parent)).as_posix())

    def test_ipa_checks_the_actual_signed_payload(self) -> None:
        ipa = self.archive.parent / 'Export.ipa'
        self.make_ipa(ipa)
        with patch.object(check_release_camera, 'imported_symbols',
                          return_value=b'_OBJC_CLASS_$_AVCaptureSession\n'):
            findings = check_release_camera.inspect(ipa)
        self.verify.assert_called_once()
        app_path = self.verify.call_args.args[0]
        self.assertEqual(app_path.parent.name, 'Payload')
        self.assertFalse(app_path.exists())
        self.assertEqual(findings, [
            ('Frameworks/WebRTC.framework/WebRTC', ('AVCaptureSession',)),
            ('RideIntercom', ('AVCaptureSession',)),
        ])

    def test_ipa_fails_if_payload_cannot_be_extracted_reliably(self) -> None:
        ipa = self.archive.parent / 'Export.ipa'
        self.make_ipa(ipa)
        with zipfile.ZipFile(ipa, 'a') as package:
            redirect = zipfile.ZipInfo('Payload/RideIntercom.app/Frameworks/Unknown')
            redirect.create_system = 3
            redirect.external_attr = (stat.S_IFLNK | 0o777) << 16
            package.writestr(redirect, 'SomeOtherFile')
        with redirect_stderr(io.StringIO()):
            self.assertEqual(check_release_camera.main([str(ipa)]), 2)
        self.verify.assert_not_called()

    def test_ipa_rejects_members_with_the_same_name_on_disk(self) -> None:
        ipa = self.archive.parent / 'Export.ipa'
        self.make_ipa(ipa)
        with zipfile.ZipFile(ipa, 'a') as package:
            package.writestr('Payload/RideIntercom.app/info.plist', 'other')
        with redirect_stderr(io.StringIO()):
            self.assertEqual(check_release_camera.main([str(ipa)]), 2)
        self.verify.assert_not_called()


if __name__ == '__main__':
    unittest.main()
