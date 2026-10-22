"""Disposable maintenance checks; never access the real Library or Keychain."""
import contextlib
import importlib.util
import io
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name).resolve()

    def git(self, *args):
        subprocess.run(['git', *args], cwd=self.root, check=True, stdout=subprocess.DEVNULL)

    def test_project_cleanup_preserves_sources_and_private_input(self):
        module = load('clean-project')
        self.git('init', '-q')
        (self.root / '.gitignore').write_text('.build/\n.local-testing/\n*.log\n')
        for relative in ('.build/test-fixture/data', '.local-testing/servers.json', 'Tests/Fixtures/source', 'tracked.log', 'debug.log'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic')
        self.git('add', '.gitignore', 'Tests/Fixtures/source')
        self.git('add', '-f', 'tracked.log')
        for path in module.targets(self.root):
            module.remove(path)
        for relative in ('.local-testing/servers.json', 'Tests/Fixtures/source', 'tracked.log'):
            self.assertEqual((self.root / relative).read_text(), 'synthetic')
        self.assertFalse((self.root / '.build/test-fixture').exists())
        self.assertFalse((self.root / 'debug.log').exists())

    def test_cleanup_refuses_redirected_build_directory(self):
        module = load('clean-project')
        self.git('init', '-q')
        outside = self.root / 'keep'
        outside.mkdir()
        (outside / 'data').write_text('keep')
        (self.root / '.build').symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, 'redirected'):
            module.targets(self.root)
        self.assertEqual((outside / 'data').read_text(), 'keep')

    def test_cleanup_preserves_all_dependency_locations(self):
        module = load('clean-project')
        self.git('init', '-q')
        for relative in module.PRESERVED:
            path = self.root / relative / 'sentinel'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('dependency')
        for relative in ('.build/Xcode/Build/app', '.build/wireguard/fixture/output',
                         '.build/rdp-fixture/server', '.build/core-tests/debug/test', 'DerivedData/Logs/log'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('generated')
        for path in module.targets(self.root):
            module.remove(path)
        for relative in module.PRESERVED:
            self.assertEqual((self.root / relative / 'sentinel').read_text(), 'dependency')
        self.assertFalse((self.root / '.build').exists())
        self.assertFalse((self.root / '.build/Xcode/Build').exists())
        self.assertFalse((self.root / '.build/wireguard/fixture').exists())
        self.assertFalse((self.root / '.build/rdp-fixture').exists())
        self.assertFalse((self.root / '.build/core-tests/debug').exists())
        self.assertFalse((self.root / 'DerivedData/Logs').exists())

    def test_test_harness_cleans_success_failure_and_child_processes(self):
        support = ROOT / 'scripts/test-support.sh'
        for status in (0, 7):
            command = f"""set -euo pipefail
source "{support}" synthetic
printf '%s' "$fixture_root" > run-path
sleep 30 &
fixture_pids+=("$!")
printf '%s' "$!" > child-pid
printf 'synthetic log' > "$fixture_root/server.log"
exit {status}
"""
            result = subprocess.run(['/bin/bash', '-c', command], cwd=self.root)
            self.assertEqual(result.returncode, status)
            self.assertFalse(Path((self.root / 'run-path').read_text()).exists())
            pid = int((self.root / 'child-pid').read_text())
            import os
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        result = subprocess.run(['/bin/bash', '-c', f'set -euo pipefail; source "{support}" empty'], cwd=self.root)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(list((self.root / '.build/tests').iterdir()), [])

    def test_semver_accepts_prefixed_tags_and_rejects_downgrades(self):
        module = load('update-dependencies')
        refs = ('a\trefs/tags/1.5.0\nb\trefs/tags/v1.9.0\n'
                'c\trefs/tags/v1.20.0\nd\trefs/tags/v1.20.0^{}\n'
                'e\trefs/tags/V1.11.1\nf\trefs/tags/v2.0.0\n'
                'g\trefs/tags/v1.21.0-beta1')
        with patch.object(module, 'run', return_value=refs):
            self.assertEqual(module.tag_pin('url', '', 'latest', '1.20.0'), ('1.20.0', 'd'))
            self.assertEqual(module.tag_pin('url', '', '1.20.0', '1.5.0'), ('1.20.0', 'd'))
            with self.assertRaisesRegex(RuntimeError, 'downgrade'):
                module.tag_pin('url', '', '1.5.0', '1.20.0')
        with patch.object(module, 'run', return_value='a\trefs/tags/1.5.0'):
            with self.assertRaisesRegex(RuntimeError, 'downgrade'):
                module.tag_pin('url', '', 'latest', '1.20.0')

    def test_cleanup_removes_read_only_go_module_cache(self):
        module = load('clean-project')
        cache = self.root / '.build/wireguard/mod/gvisor.dev/gvisor@synthetic'
        nested = cache / 'pkg/nested'
        nested.mkdir(parents=True)
        (nested / 'source.go').write_text('synthetic')
        (nested / 'source.go').chmod(0o444)
        for path in (nested, nested.parent, cache):
            path.chmod(0o555)
        module.remove(self.root / '.build')
        self.assertFalse((self.root / '.build').exists())

    def test_master_pin_requires_exact_upstream_branch(self):
        module = load('update-dependencies')
        revision = 'b' * 40
        with patch.object(module, 'run', return_value=revision + '\trefs/heads/master'):
            self.assertEqual(module.master_pin('url'), revision)
        for response in ('', 'invalid\trefs/heads/master', revision + '\trefs/heads/other',
                         (revision + '\trefs/heads/master\n') * 2):
            with patch.object(module, 'run', return_value=response):
                with self.assertRaisesRegex(RuntimeError, 'master revision'):
                    module.master_pin('url')

    def test_native_fetch_uses_pinned_commit_after_branch_moves(self):
        self.git('init', '-q')
        self.git('-c', 'user.name=Synthetic', '-c', 'user.email=synthetic@example.invalid',
                 'commit', '--allow-empty', '-qm', 'pinned')
        revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=self.root, text=True).strip()
        self.git('-c', 'user.name=Synthetic', '-c', 'user.email=synthetic@example.invalid',
                 'commit', '--allow-empty', '-qm', 'newer')
        prepare = (ROOT / 'scripts/prepare-dependencies.sh').read_text()
        fetch = 'fetch() {' + prepare.split('fetch() {', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
        source_root = self.root / 'sources'
        source_root.mkdir()
        command = 'set -euo pipefail\nsource_root="$1"\n' + fetch + '\nfetch synthetic "$2" master "$3"'
        args = ['/bin/bash', '-c', command, 'fetch-test', str(source_root), str(self.root), revision]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_root / 'synthetic', text=True).strip()
        self.assertEqual(actual, revision)
        # A cached source at a different revision must fail rather than build it.
        args[-1] = 'b' * 40
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected revision', result.stderr)

    def test_libssh2_latest_retains_master_and_invalidates_old_binaries(self):
        module = load('update-dependencies')
        for relative in ('scripts/clean-project.py', 'scripts/prepare-dependencies.sh',
                         'Farcast.xcodeproj/project.pbxproj', 'ThirdParty/README.md'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, path)
        module.ROOT = self.root
        module.PREPARE = self.root / 'scripts/prepare-dependencies.sh'
        module.PROJECT = self.root / 'Farcast.xcodeproj/project.pbxproj'
        module.RESOLVED = self.root / 'Package.resolved'
        module.GO = self.root / 'Networking/VPN'
        self.git('init', '-q')
        old_library = self.root / 'Vendor/Native/lib/old.dylib'
        old_library.parent.mkdir(parents=True)
        old_library.write_text('stale synthetic binary')
        revision = 'b' * 40
        with patch('sys.argv', ['update', '--libssh2', 'latest', '--apply']), \
             patch.object(module, 'master_pin', return_value=revision), \
             patch.object(module, 'tag_pin', side_effect=AssertionError('Must not select release tags')), \
             contextlib.redirect_stdout(io.StringIO()):
            module.main()
        self.assertIn('master ' + revision, module.PREPARE.read_text())
        self.assertIn('master `' + revision + '`', (self.root / 'ThirdParty/README.md').read_text())
        self.assertFalse(old_library.exists())
        with patch('sys.argv', ['update', '--libssh2', '1.11.1']), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'patched master'):
                module.main()

    def test_read_only_cleanup_preserves_external_link_permissions(self):
        module = load('clean-project')
        cache = self.root / '.build/mod'
        cache.mkdir(parents=True)
        outside = self.root / 'keep'
        outside.mkdir()
        external = outside / 'source'
        external.write_text('keep')
        external.chmod(0o444)
        (cache / 'hardlink').hardlink_to(external)
        (cache / 'symlink').symlink_to(outside, target_is_directory=True)
        cache.chmod(0o555)
        outside.chmod(0o555)
        try:
            module.remove(self.root / '.build')
            self.assertEqual(external.read_text(), 'keep')
            self.assertEqual(stat.S_IMODE(external.stat().st_mode), 0o444)
            self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o555)
        finally:
            outside.chmod(0o755)

    def test_cleanup_refuses_tracked_generated_target(self):
        module = load('clean-project')
        self.git('init', '-q')
        (self.root / 'build').mkdir()
        (self.root / 'build/source').write_text('keep')
        self.git('add', 'build/source')
        with self.assertRaises(RuntimeError):
            module.targets(self.root)

    def test_tag_resolution_peels_annotated_tags_and_ignores_new_major(self):
        module = load('update-dependencies')
        refs = 'a\trefs/tags/3.1.0\nb\trefs/tags/3.2.0\nc\trefs/tags/3.2.0^{}\nd\trefs/tags/4.0.0\ne\trefs/tags/3.3.0-rc1'
        with patch.object(module, 'run', return_value=refs):
            self.assertEqual(module.tag_pin('url', '', 'latest', '3.1.0'), ('3.2.0', 'c'))
            with self.assertRaises(RuntimeError):
                module.tag_pin('url', '', '3.9.0', '3.1.0')

    def test_updater_rolls_back_pin_changes_on_resolution_failure(self):
        module = load('update-dependencies')
        for relative in ('scripts/update-dependencies.py', 'scripts/clean-project.py', 'scripts/prepare-dependencies.sh',
                         'Farcast.xcodeproj/project.pbxproj',
                         'Farcast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                         'Networking/VPN/go.mod', 'Networking/VPN/go.sum',
                         'ThirdParty/README.md', 'ThirdParty/WireGuard-build-modules.txt'):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, path)
        module = load('update-dependencies')
        module.ROOT = self.root
        module.PREPARE = self.root / 'scripts/prepare-dependencies.sh'
        module.PROJECT = self.root / 'Farcast.xcodeproj/project.pbxproj'
        module.RESOLVED = self.root / 'Farcast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        module.GO = self.root / 'Networking/VPN'
        self.git('init', '-q')
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file() and '.git' not in p.parts}
        with patch('sys.argv', ['update', '--swiftterm', '1.21.0', '--apply']), \
             patch.object(module, 'tag_pin', return_value=('1.21.0', 'a' * 40)), \
             patch.object(module, 'run', side_effect=RuntimeError('synthetic resolve failure')), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                module.main()
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)

    def test_user_reset_success_removes_only_owned_storage(self):
        module = load('clean-user-data')
        owned = self.root / 'Library/Application Support/Farcast'
        owned.mkdir(parents=True)
        (owned / 'record').write_text('synthetic')
        other = self.root / 'Library/Application Support/OtherApp'
        other.mkdir()
        (other / 'record').write_text('keep')
        def fake_run(args, **kwargs):
            return subprocess.CompletedProcess(args, 1 if args[0] == 'pgrep' else 0)
        with patch('sys.argv', ['reset', '--apply']), patch.object(module.os, 'geteuid', return_value=501), \
             patch.object(module.Path, 'home', return_value=self.root), \
             patch.object(module.tempfile, 'gettempdir', return_value=str(self.root)), \
             patch.object(module.subprocess, 'run', side_effect=fake_run), \
             contextlib.redirect_stdout(io.StringIO()):
            module.main()
        self.assertFalse(owned.exists())
        self.assertEqual((other / 'record').read_text(), 'keep')

    def test_user_reset_refuses_running_app(self):
        module = load('clean-user-data')
        with patch('sys.argv', ['reset', '--apply']), patch.object(module.os, 'geteuid', return_value=501), \
             patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'Quit'):
                module.main()

    def test_user_reset_is_exactly_scoped_and_keychain_failure_preserves_files(self):
        module = load('clean-user-data')
        library = self.root / 'Library/Application Support/Farcast'
        library.mkdir(parents=True)
        (library / 'synthetic').write_text('keep')
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            if args[0] == 'pgrep':
                return subprocess.CompletedProcess(args, 1)
            if args[0] == 'xcrun':
                return subprocess.CompletedProcess(args, 0)
            raise subprocess.CalledProcessError(1, args)
        with patch('sys.argv', ['reset', '--apply']), patch.object(module.os, 'geteuid', return_value=501), \
             patch.object(module.Path, 'home', return_value=self.root), \
             patch.object(module.tempfile, 'gettempdir', return_value=str(self.root)), \
             patch.object(module.subprocess, 'run', side_effect=fake_run), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                module.main()
        self.assertEqual((library / 'synthetic').read_text(), 'keep')
        self.assertIn('kSecAttrService', module.KEYCHAIN_SOURCE)
        self.assertIn('com.peterpo.farcast.credentials', module.KEYCHAIN_SOURCE)
        self.assertNotIn('SecItemCopyMatching', module.KEYCHAIN_SOURCE)
        self.assertFalse(any(c[0] == 'defaults' for c in calls))


if __name__ == '__main__':
    unittest.main()
