import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('showcase_prepare', ROOT / 'Showcase/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class ShowcaseIsolation(unittest.TestCase):
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
        session = (destination / 'Farcast/Features/Sessions/RemoteSession.swift').read_text()
        start = session.split('func start(credential: ConnectionCredential) {', 1)[1].split('private func startProtocol', 1)[0]
        self.assertEqual(start.strip(), 'startShowcase()\n    }')
        credential = (destination / 'Farcast/Shared/Security/CredentialStore.swift').read_text()
        self.assertNotIn('SecItemCopyMatching', credential)
        self.assertNotIn('LocalCredentialStore()', credential)
        self.assertTrue((destination / 'Farcast/catalog.json').is_file())
