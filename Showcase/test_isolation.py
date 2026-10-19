import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('showcase_prepare', ROOT / 'Showcase/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class ShowcaseIsolation(unittest.TestCase):
    def validate(self, catalog):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'catalog.json'
            path.write_text(json.dumps(catalog))
            return prepare.validate_catalog(path)

    def test_edited_catalog_sizes(self):
        catalog = json.loads((ROOT / 'Showcase/catalog.json').read_text())
        # A smaller valid catalog is supported, including an SSH-only demo without VPNs.
        catalog['connections'] = catalog['connections'][:1]
        catalog['connections'][0].pop('vpn', None)
        catalog['vpns'] = []
        self.assertEqual(len(self.validate(catalog)['connections']), 1)

    def test_catalog_rejects_invalid_metadata(self):
        original = json.loads((ROOT / 'Showcase/catalog.json').read_text())
        for field, value in [('vpn', -1), ('vpn', len(original['vpns'])), ('vpn', True),
                             ('kind', 'UNKNOWN'), ('favorite', 'false')]:
            with self.subTest(field=field, value=value):
                catalog = json.loads(json.dumps(original))
                catalog['connections'][0][field] = value
                with self.assertRaises(ValueError):
                    self.validate(catalog)
        with self.assertRaises(ValueError):
            self.validate({'connections': [], 'vpns': []})

    def test_sftp_panes_allow_independent_content_at_same_path(self):
        catalog = json.loads((ROOT / 'Showcase/catalog.json').read_text())
        catalog['sftp'] = {
            'local': {'path': '/same', 'folders': {'/same': []}},
            'remote': {'path': '/same', 'folders': {'/same': [
                {'name': 'server-only.txt', 'directory': False, 'size': 43}]}}}
        result = self.validate(catalog)['sftp']
        self.assertEqual(result['local']['folders']['/same'], [])
        self.assertEqual(result['remote']['folders']['/same'][0]['size'], 43)

    def test_sftp_rejects_invalid_folder_content(self):
        original = json.loads((ROOT / 'Showcase/catalog.json').read_text())
        for side in ['local', 'remote']:
            for change in ['relative', 'missing', 'negative', 'boolean_size', 'duplicate']:
                with self.subTest(side=side, change=change):
                    catalog = json.loads(json.dumps(original))
                    pane = catalog['sftp'][side]
                    entries = pane['folders'][pane['path']]
                    if change == 'relative':
                        pane['path'] = 'relative'
                    elif change == 'missing':
                        pane['folders'] = {}
                    elif change == 'negative':
                        entries[0]['size'] = -1
                    elif change == 'boolean_size':
                        entries[0]['size'] = True
                    else:
                        entries.append(entries[0].copy())
                    with self.assertRaises(ValueError):
                        self.validate(catalog)

    def test_catalog_rejects_trailing_comma(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'catalog.json'
            path.write_text('{"connections": [], "vpns": [],}')
            with self.assertRaises(ValueError):
                prepare.validate_catalog(path)

    def test_verifier_rejects_stale_version_or_build_before_launch(self):
        config = (ROOT / 'Version.xcconfig').read_text()
        version = re.search(r'^MARKETING_VERSION = (\S+)', config, re.MULTILINE)[1]
        build = re.search(r'^CURRENT_PROJECT_VERSION = (\S+)', config, re.MULTILINE)[1]
        for stale_version, stale_build in [('0.0.0', build), (version, '0')]:
            with self.subTest(version=stale_version, build=stale_build), tempfile.TemporaryDirectory() as directory:
                contents = Path(directory) / 'Farcast.app/Contents'
                contents.mkdir(parents=True)
                (contents / 'Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleShortVersionString': stale_version, 'CFBundleVersion': stale_build}))
                result = subprocess.run([sys.executable, str(ROOT / 'Showcase/verify.py'), str(contents.parent)],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('does not match Version.xcconfig', result.stderr)
                self.assertNotIn('Traceback', result.stderr)

    def test_production_has_no_showcase_integration(self):
        for source in (ROOT / 'Farcast').rglob('*.swift'):
            text = source.read_text()
            self.assertNotIn('ShowcaseLibrary', text)
            self.assertNotIn('startShowcase', text)
        project = (ROOT / 'Farcast.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('Showcase', project)
        self.assertNotIn('showcase', project)

    def test_dmg_stages_only_production_app(self):
        script = (ROOT / 'scripts/build-dmg.sh').read_text()
        self.assertIn('Release/Farcast.app', script)
        self.assertNotIn('Farcast-demo.app', script)

    def test_generated_sources_replace_entry_points(self):
        # Run prepare.py before this suite; never regenerate during an active build.
        destination = prepare.DEST
        self.assertIn('isStoredInMemoryOnly: true', (destination / 'Farcast/App/FarcastApp.swift').read_text())
        self.assertIn('FAIL showcase:', (destination / 'Farcast/App/FarcastApp.swift').read_text())
        session = (destination / 'Farcast/Features/Sessions/RemoteSession.swift').read_text()
        start = session.split('func start(credential: ConnectionCredential) {', 1)[1].split('private func startProtocol', 1)[0]
        self.assertEqual(start.strip(), 'startShowcase()\n    }')
        credential = (destination / 'Farcast/Shared/Security/CredentialStore.swift').read_text()
        self.assertNotIn('SecItemCopyMatching', credential)
        self.assertNotIn('LocalCredentialStore()', credential)
        self.assertTrue((destination / 'Farcast/catalog.json').is_file())
