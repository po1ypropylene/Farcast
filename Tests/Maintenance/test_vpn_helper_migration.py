"""Source-only migration checks against disposable older checkouts."""
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vpn_migration', ROOT / 'scripts/migrate-vpn-helper.py')
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class VPNHelperMigrationTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.old = self.root / 'Networking/WireGuard'
        self.old.mkdir(parents=True)
        (self.old / 'go.mod').write_text('module com.peterpo.farcast/wireguard\n')
        (self.old / 'main.go').write_bytes(b'package main\n')
        self.reference = self.root / 'scripts/prepare-wireguard.sh'
        self.reference.parent.mkdir()
        self.reference.write_text('cd Networking/WireGuard\n')
        self.reference.chmod(0o755)

    def test_migrate_preserves_sources_permissions_and_unrelated_data(self):
        sentinel = self.root / 'unrelated'
        sentinel.write_bytes(b'keep unchanged')
        self.assertTrue(migration.migrate(self.root))
        new = self.root / 'Networking/VPN'
        self.assertFalse(self.old.exists())
        self.assertEqual((new / 'main.go').read_bytes(), b'package main\n')
        self.assertEqual((new / 'go.mod').read_text(), 'module com.peterpo.farcast/vpn\n')
        self.assertEqual(self.reference.read_text(), 'cd Networking/VPN\n')
        self.assertEqual(self.reference.stat().st_mode & 0o777, 0o755)
        self.assertEqual(sentinel.read_bytes(), b'keep unchanged')
        self.assertFalse(migration.migrate(self.root))

    def test_collision_fails_without_partial_edits(self):
        (self.root / 'Networking/VPN').mkdir()
        with self.assertRaises(RuntimeError):
            migration.migrate(self.root)
        self.assertTrue((self.old / 'main.go').is_file())
        self.assertEqual(self.reference.read_text(), 'cd Networking/WireGuard\n')

    def test_redirected_reference_fails_before_move(self):
        target = self.root / 'untouched'
        target.write_text('Networking/WireGuard')
        self.reference.unlink()
        self.reference.symlink_to(target)
        with self.assertRaises(RuntimeError):
            migration.migrate(self.root)
        self.assertTrue((self.old / 'main.go').is_file())
        self.assertEqual(target.read_text(), 'Networking/WireGuard')
