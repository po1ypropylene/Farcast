"""Exercise packaging with disposable bundles and mocked disk/signing tools."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DMGPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        shutil.copy2(ROOT / 'scripts/build-dmg.sh', scripts)
        # Any accidental build invocation must fail, even without Xcode installed.
        (scripts / 'build.sh').write_text('#!/bin/bash\necho unexpected-build >&2\nexit 99\n')
        (scripts / 'build.sh').chmod(0o755)
        for name in ('verify-bundle.py', 'local-signing.py'):
            (scripts / name).write_text(
                'import os, pathlib, sys\n'
                'with pathlib.Path("checks").open("a") as f: f.write(" ".join(sys.argv) + "\\n")\n'
                'sys.exit(int(os.environ.get("VERIFY_EXIT", "0")))\n'
            )
        (self.root / 'Version.xcconfig').write_text(
            'MARKETING_VERSION = 1.4.0\nCURRENT_PROJECT_VERSION = 1\n')
        for name in ('CHANGELOG.md', 'LICENSE'):
            (self.root / name).write_text(name + '\n')
        self.app = self.root / '.build/Xcode/Build/Products/Release/Farcast.app'
        (self.app / 'Contents').mkdir(parents=True)
        with (self.app / 'Contents/Info.plist').open('wb') as file:
            plistlib.dump({'CFBundleShortVersionString': '1.4.0', 'CFBundleVersion': '1'}, file)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        mock = '''#!/usr/bin/env python3
import pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == 'ditto':
    shutil.copytree(args[0], args[1], symlinks=True)
elif name == 'diskutil' and args[:2] == ['image', 'create']:
    pathlib.Path(args[-1]).write_bytes(b'synthetic disk image')
elif name == 'diskutil' and args[:2] == ['image', 'attach']:
    mount = pathlib.Path(args[args.index('--mountPoint') + 1])
    shutil.copytree(mount.parent / 'payload', mount, dirs_exist_ok=True, symlinks=True)
'''
        for name in ('ditto', 'diskutil', 'hdiutil'):
            path = self.bin / name
            path.write_text(mock)
            path.chmod(0o755)

    def run_packaging(self, **extra):
        return subprocess.run(
            ['bash', 'scripts/build-dmg.sh'], cwd=self.root,
            env={**os.environ, 'PATH': f'{self.bin}:{os.environ["PATH"]}', **extra},
            text=True, capture_output=True,
        )

    def test_packages_existing_build_one_without_building_or_modifying_it(self):
        original = (self.app / 'Contents/Info.plist').read_bytes()
        config = (self.root / 'Version.xcconfig').read_bytes()
        for _ in range(2):
            result = self.run_packaging()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / 'Contents/Info.plist').read_bytes(), original)
        self.assertEqual((self.root / 'Version.xcconfig').read_bytes(), config)
        release = self.root / '.build/releases'
        self.assertTrue((release / 'Farcast-1.4.0-build-1-arm64.dmg').is_file())
        checked = subprocess.run(['shasum', '-a', '256', '-c',
                                  'Farcast-1.4.0-build-1-arm64.dmg.sha256'],
                                 cwd=release, capture_output=True)
        self.assertEqual(checked.returncode, 0)
        checks = (self.root / 'checks').read_text()
        self.assertEqual(checks.count('verify-bundle.py'), 4)
        self.assertEqual(checks.count('local-signing.py verify'), 4)
        self.assertIn('/mount/Farcast.app', checks)

    def test_missing_app_requires_explicit_build(self):
        shutil.rmtree(self.app)
        result = self.run_packaging()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Run scripts/build.sh', result.stderr)
        self.assertFalse((self.root / '.build/releases').exists())

    def test_version_or_build_mismatch_stops_before_staging(self):
        for version, build in [('1.5.0', '1'), ('1.4.0', '2')]:
            (self.root / 'Version.xcconfig').write_text(
                f'MARKETING_VERSION = {version}\nCURRENT_PROJECT_VERSION = {build}\n')
            result = self.run_packaging()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('does not match Version.xcconfig', result.stderr)
            self.assertFalse((self.root / '.build/releases').exists())

    def test_verification_failure_stops_before_staging(self):
        result = self.run_packaging(VERIFY_EXIT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / '.build/releases').exists())


if __name__ == '__main__':
    unittest.main()
