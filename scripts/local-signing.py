#!/usr/bin/env python3
"""Keep local app updates on a certificate-backed signing identity, without reading secrets."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / '.local-signing/identity.json'

def identities(output):
    return [(fingerprint.upper(), name) for fingerprint, name in
            re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "([^"]+)"\s*$', output, re.M)]

def select(available, saved, requested):
    if requested == '-':
        return '-'
    identity = requested or saved.get('identity')
    if identity:
        matches = [value for value, name in available if value == identity.upper()]
        if len(matches) != 1:
            raise RuntimeError('The selected signing certificate is unavailable or expired. Renew it in Xcode, then set FARCAST_SIGNING_IDENTITY to its SHA1 fingerprint. No ad-hoc fallback was used.')
        return matches[0]
    candidates = [value for value, name in available if name.startswith('Apple Development:')]
    if len(candidates) != 1:
        raise RuntimeError('Install an Apple Development certificate in Xcode, or select an installed certificate with FARCAST_SIGNING_IDENTITY=<SHA1>. Ad-hoc scratch builds require an explicit FARCAST_SIGNING_IDENTITY=-.')
    return candidates[0]

def check_requirement(saved, requirement):
    if ('cdhash' in requirement or 'identifier "com.peterpo.farcast"' not in requirement
            or 'anchor apple generic' not in requirement or 'certificate leaf' not in requirement):
        raise RuntimeError('The app needs a certificate-backed Farcast designated requirement, not a build-specific hash.')
    if saved.get('requirement') and saved['requirement'] != requirement:
        raise RuntimeError('The app signing requirement changed. Restore the previous signing configuration; switching signing teams/channels requires an explicit reviewed migration.')

def signing(app):
    result = subprocess.check_output(['codesign', '-d', '-r-', str(app)], stderr=subprocess.STDOUT, text=True)
    requirement = next((line.split('=>', 1)[1].strip() for line in result.splitlines()
                        if line.startswith('designated =>')), None)
    if not requirement:
        raise RuntimeError('The app has no certificate-backed designated requirement.')
    return requirement

def main():
    saved = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    mode = sys.argv[1]
    if mode == 'select':
        output = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
        print(select(identities(output), saved, os.environ.get('FARCAST_SIGNING_IDENTITY')))
    elif mode in ('record', 'verify'):
        # Explicit scratch builds make no claim of continuity and never change the pin.
        if os.environ.get('FARCAST_SIGNING_IDENTITY') == '-':
            print('NOTE: explicit ad-hoc build; Keychain approval can recur after updates.')
            return
        requirement = signing(Path(sys.argv[2]))
        check_requirement(saved, requirement)
        if mode == 'record':
            identity = sys.argv[3]
            CONFIG.parent.mkdir(mode=0o700, exist_ok=True)
            if CONFIG.parent.is_symlink() or CONFIG.is_symlink():
                raise RuntimeError('Local signing configuration must not be a symbolic link.')
            CONFIG.parent.chmod(0o700)
            fd, name = tempfile.mkstemp(prefix='.identity-', suffix='.tmp', dir=CONFIG.parent)
            temporary = Path(name)
            try:
                with os.fdopen(fd, 'w') as file:
                    json.dump({'identity': identity, 'requirement': requirement}, file, indent=2)
                    file.write('\n')
                temporary.replace(CONFIG)
            finally:
                temporary.unlink(missing_ok=True)
        elif not saved.get('requirement'):
            raise RuntimeError('No verified local signing baseline exists. Build the app first.')
        print('PASS certificate-backed signing continuity.')
    else:
        raise RuntimeError('Expected select, record or verify.')

if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
