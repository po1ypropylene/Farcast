"""Signing-policy checks use public synthetic identities; never access a real keychain."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('local_signing', ROOT / 'scripts/local-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
FIRST, SECOND = 'A' * 40, 'B' * 40
REQUIREMENT = ('identifier "com.peterpo.farcast" and anchor apple generic '
               'and certificate leaf[subject.OU] = "SYNTHETIC"')

class LocalSigningTests(unittest.TestCase):
    def test_identity_parser_ignores_invalid_rows(self):
        text = f'  1) {FIRST} "Apple Development: Synthetic"\n  2) invalid "Other"\n 1 valid identities found\n'
        self.assertEqual(signing.identities(text), [(FIRST, 'Apple Development: Synthetic')])

    def test_first_build_requires_an_unambiguous_development_certificate(self):
        self.assertEqual(signing.select([(FIRST, 'Apple Development: Synthetic')], {}, None), FIRST)
        for available in ([], [(FIRST, 'Apple Development: A'), (SECOND, 'Apple Development: B')]):
            with self.assertRaises(RuntimeError): signing.select(available, {}, None)

    def test_pin_prevents_switching_to_another_available_identity(self):
        available = [(SECOND, 'Apple Development: New'), (FIRST, 'Apple Development: Original')]
        self.assertEqual(signing.select(available, {'identity': FIRST}, None), FIRST)
        with self.assertRaisesRegex(RuntimeError, 'No ad-hoc fallback'):
            signing.select(available[:1], {'identity': FIRST}, None)

    def test_explicit_certificate_selection_and_missing_certificate(self):
        available = [(SECOND, 'Apple Development: Renewal')]
        self.assertEqual(signing.select(available, {'identity': FIRST}, SECOND.lower()), SECOND)
        with self.assertRaises(RuntimeError): signing.select(available, {}, FIRST)

    def test_ad_hoc_requires_explicit_opt_in(self):
        self.assertEqual(signing.select([], {'identity': FIRST}, '-'), '-')
        with self.assertRaises(RuntimeError): signing.select([], {}, None)

    def test_build_hash_and_identifier_only_requirements_are_rejected(self):
        for requirement in ('cdhash H"1234"', 'identifier "com.peterpo.farcast"',
                            REQUIREMENT.replace('com.peterpo.farcast', 'com.example.other')):
            with self.assertRaises(RuntimeError): signing.check_requirement({}, requirement)

    def test_changed_signing_channel_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'requirement changed'):
            signing.check_requirement({'requirement': REQUIREMENT}, REQUIREMENT + ' and certificate 1[field.1.2.3] exists')

    def test_rebuild_keeps_recorded_requirement(self):
        signing.check_requirement({}, REQUIREMENT)
        signing.check_requirement({'identity': FIRST, 'requirement': REQUIREMENT}, REQUIREMENT)

if __name__ == '__main__': unittest.main()
