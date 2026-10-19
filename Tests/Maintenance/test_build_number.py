"""Build reservations survive marketing-version changes and reject invalid input."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('build_number', ROOT / 'scripts/advance-build-number.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildNumberTests(unittest.TestCase):
    def test_reservations_continue_across_versions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Version.xcconfig'
            path.write_text('// retained\nMARKETING_VERSION = 1.5.0\nCURRENT_PROJECT_VERSION = 9999\n')
            self.assertEqual(module.advance(path), 10000)
            path.write_text(path.read_text().replace('1.5.0', '2.0.0'))
            self.assertEqual(module.advance(path), 10001)
            self.assertEqual(path.read_text(),
                             '// retained\nMARKETING_VERSION = 2.0.0\nCURRENT_PROJECT_VERSION = 10001\n')

    def test_invalid_configuration_is_unchanged(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'Version.xcconfig'
            for source in ['', 'CURRENT_PROJECT_VERSION = 0\n',
                           'CURRENT_PROJECT_VERSION = -1\n',
                           'CURRENT_PROJECT_VERSION = 1.2\n',
                           'CURRENT_PROJECT_VERSION = 3\nCURRENT_PROJECT_VERSION = 4\n']:
                path.write_text(source)
                with self.assertRaises(ValueError):
                    module.advance(path)
                self.assertEqual(path.read_text(), source)
