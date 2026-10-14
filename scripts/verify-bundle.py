#!/usr/bin/env python3
"""Validate platform, dependency closure and signing, then exercise the macOS loader."""
import plistlib
import re
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if any(info.get(key) != expected for key, expected in {
        'CFBundleIdentifier': 'com.peterpo.farcast', 'CFBundleDisplayName': 'Farcast',
        'CFBundleName': 'Farcast', 'CFBundleExecutable': 'Farcast'}.items()):
    raise SystemExit('The final app must use the Farcast display name, executable and lowercase bundle identity.')
if float(info.get('LSMinimumSystemVersion', '0').split('.')[0]) < 27:
    raise SystemExit('The app must require macOS 27 or later.')
executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
if not (app / 'Contents/MacOS/FarcastWireGuard').is_file():
    raise SystemExit('Missing embedded WireGuard helper.')
project_root = Path(__file__).resolve().parent.parent
if (app / 'Contents/Resources/LICENSE').read_bytes() != (project_root / 'LICENSE').read_bytes():
    raise SystemExit('The app must include the current Farcast MIT license.')
for notice in (project_root / 'ThirdParty').iterdir():
    if notice.is_file() and (app / 'Contents/Resources/ThirdParty' / notice.name).read_bytes() != notice.read_bytes():
        raise SystemExit('The app must include all current third-party notices.')
libraries = list((app / 'Contents/Frameworks').glob('*.dylib'))

def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)

def signing(path):
    details = command('codesign', '-dv', '--verbose=4', str(path))
    team = next((line.split('=', 1)[1] for line in details.splitlines() if line.startswith('TeamIdentifier=')), None)
    return details, team

command('codesign', '--verify', '--deep', '--strict', str(app))
app_signing, app_team = signing(executable)
if 'Signature=adhoc' in app_signing and '(runtime)' in app_signing:
    raise SystemExit('Ad-hoc signing with hardened runtime rejects the bundled libraries. Use scripts/build.sh.')
binaries = list((app / 'Contents/MacOS').iterdir()) + libraries
for binary in binaries:
    if not binary.is_file():
        continue
    if command('lipo', '-archs', str(binary)).strip() != 'arm64':
        raise SystemExit(f'{binary.name} must contain only arm64.')
    load_commands = command('otool', '-l', str(binary)).splitlines()
    minima = []
    active_command = ''
    for line in load_commands:
        words = line.strip().split()
        if len(words) == 2 and words[0] == 'cmd':
            active_command = words[1]
        if len(words) == 2 and ((active_command == 'LC_BUILD_VERSION' and words[0] == 'minos') or
                                (active_command == 'LC_VERSION_MIN_MACOSX' and words[0] == 'version')):
            minima.append(words[1])
    if not minima or any(int(value.split('.')[0]) < 27 for value in minima):
        raise SystemExit(f'{binary.name} must target macOS 27 or later.')
    if signing(binary)[1] != app_team:
        raise SystemExit(f'{binary.name} has a different signing team.')
    for line in command('otool', '-L', str(binary)).splitlines()[1:]:
        dependency = line.strip().split(' (compatibility')[0]
        if dependency.startswith(('/System/', '/usr/lib/')):
            continue
        if dependency.startswith('@rpath/') and any((app / folder / Path(dependency).name).exists() for folder in ['Contents/Frameworks', 'Contents/MacOS']):
            continue
        raise SystemExit(f'{binary.name} has an unresolved dependency: {dependency}')
def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True, check=True)
    return plistlib.loads(result.stdout) if result.stdout else {}
parent_rights = entitlements(executable)
if not all(parent_rights.get(key) is True for key in ['com.apple.security.app-sandbox',
        'com.apple.security.network.client', 'com.apple.security.network.server',
        'com.apple.security.files.user-selected.read-write', 'com.apple.security.files.bookmarks.app-scope']):
    raise SystemExit('App must retain App Sandbox, network rights and selected-file/bookmark access.')
helper_rights = entitlements(app / 'Contents/MacOS/FarcastWireGuard')
if 'Identifier=com.peterpo.farcast.wireguard' not in signing(app / 'Contents/MacOS/FarcastWireGuard')[0].splitlines():
    raise SystemExit('The embedded helper must use the lowercase Farcast signing identity.')
expected_helper_rights = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
if helper_rights != expected_helper_rights:
    raise SystemExit('WireGuard helper must have exactly the sandbox and inheritance entitlements.')
# These exit before creating the connection library/UI and never load saved keys.
result = subprocess.run([str(executable), '--verify-bundle-launch'], capture_output=True, text=True, timeout=15)
if result.returncode != 0 or 'Farcast loader check passed' not in result.stdout:
    raise SystemExit('Packaged app failed its loader check. Inspect local build diagnostics.')
probe = subprocess.run([str(executable), '--verify-wireguard-helper'], capture_output=True, text=True, timeout=25)
if probe.returncode != 0 or 'Farcast sandboxed WireGuard helper check passed' not in probe.stdout:
    raise SystemExit('Packaged app failed its sandboxed WireGuard helper check. No real-server settings were used.')
listener = subprocess.run([str(executable), '--verify-ssh-listener'], capture_output=True, text=True, timeout=15)
if listener.returncode != 0 or 'Farcast sandboxed SSH listener check passed' not in listener.stdout:
    # The probe's own stage codes contain no user/session data.
    diagnostic = re.search(r'SSH listener probe: (bind|accept/data) failed \([0-9]+\)\.', listener.stderr)
    if diagnostic:
        print(diagnostic.group(0))
    raise SystemExit('Packaged app failed its sandboxed SSH listener check. No real-server settings were used.')
print(f'PASS bundle: macOS 27+, arm64, {len(libraries)} native libraries, signatures, loader, sandboxed SSH listeners and WireGuard helper.')
