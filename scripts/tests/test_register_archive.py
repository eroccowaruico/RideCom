from __future__ import annotations

import plistlib
import shutil
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from scripts import register_archive


class RegisterArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.archives = self.root / 'Archives'
        self.source = self.root / 'Source.xcarchive'
        self.product = self.source / 'Products/Applications/RideIntercom.app'
        self.product.mkdir(parents=True)
        self.bundle = {'CFBundleIdentifier': register_archive.BUNDLE_ID, 'CFBundleShortVersionString': '1.0',
                       'CFBundleVersion': '25', 'StorageNamespace': 'RideIntercom',
                       'CFBundleSupportedPlatforms': ['iPhoneOS'], 'CFBundleExecutable': 'RideIntercom'}
        self.properties = {key: self.bundle[key] for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')}
        self.properties.update(ApplicationPath='Applications/RideIntercom.app', SigningIdentity='Apple Development')
        self.info = {'CreationDate': datetime(2026, 11, 21, 12), 'ApplicationProperties': self.properties}
        self.write_metadata()
        self.binary = self.product / 'RideIntercom'
        self.binary.write_bytes(b'App executable')
        self.symbols = self.source / 'dSYMs/RideIntercom.app.dSYM/Contents/Resources/DWARF/RideIntercom'
        self.symbols.parent.mkdir(parents=True)
        self.symbols.write_bytes(b'dSYM content')
        self.verify = patch.object(register_archive, 'check_signature_and_symbols', autospec=True).start()
        self.addCleanup(patch.stopall)

    def write_metadata(self) -> None:
        (self.product / 'Info.plist').write_bytes(plistlib.dumps(self.bundle))
        (self.source / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def test_signed_archive_is_copied_without_changing_metadata_or_symbols(self) -> None:
        def copy(command: list[str | Path], **_: object) -> None:
            shutil.copytree(command[1], command[2])
        with patch.object(register_archive.subprocess, 'run', side_effect=copy) as ditto:
            saved = register_archive.register(self.source, self.archives)
            self.assertEqual(saved.name, 'RideIntercom iOS 1.0 (25).xcarchive')
            self.assertEqual((saved / 'Info.plist').read_bytes(), (self.source / 'Info.plist').read_bytes())
            self.assertEqual((saved / self.symbols.relative_to(self.source)).read_bytes(), self.symbols.read_bytes())
            self.assertEqual(register_archive.register(saved, self.archives), saved)
            with self.assertRaises(FileExistsError):
                register_archive.register(self.source, self.archives)
            self.assertEqual(ditto.call_count, 1)

    def test_validation_archive_or_mismatched_metadata_is_rejected_before_copying(self) -> None:
        self.bundle['StorageNamespace'] = 'RideIntercom.Validation.Xcode'
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, 'Release'):
            register_archive.register(self.source, self.archives)
        self.bundle['StorageNamespace'] = 'RideIntercom'
        self.bundle['CFBundleVersion'] = '26'
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, 'metadata'):
            register_archive.register(self.source, self.archives)
        self.assertFalse(self.archives.exists())
        self.verify.assert_not_called()

    def test_copy_failure_does_not_publish_partial_archive(self) -> None:
        def interrupt(command: list[str | Path], **_: object) -> None:
            Path(command[2]).mkdir()
            raise OSError('archive copy interrupted')
        with (
            patch.object(register_archive.subprocess, 'run', side_effect=interrupt),
            self.assertRaisesRegex(OSError, 'interrupted'),
        ):
            register_archive.register(self.source, self.archives)
        self.assertEqual(list(self.archives.glob('*/*')), [])
        self.assertTrue(self.binary.is_file())

    def test_destination_created_during_copy_is_preserved(self) -> None:
        def copy(command: list[str | Path], **_: object) -> None:
            staged = Path(command[2])
            shutil.copytree(command[1], staged)
            (staged.parent.parent / staged.name).mkdir()
        with (
            patch.object(register_archive.subprocess, 'run', side_effect=copy),
            self.assertRaises(FileExistsError),
        ):
            register_archive.register(self.source, self.archives)
        saved, = self.archives.glob('*/*.xcarchive')
        self.assertEqual(list(saved.iterdir()), [])
