#!/usr/bin/env python3
"""Copy the native dependency closure, relocate load commands, and sign bundled libraries."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

app, prefix = map(Path, sys.argv[1:3])
identity = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else '-'
# Refuse the exact configuration that caused the two DYLD crashes on 7 October.
if identity == '-' and os.environ.get('ENABLE_HARDENED_RUNTIME') == 'YES':
    raise SystemExit('Ad-hoc signing requires ENABLE_HARDENED_RUNTIME=NO. Developer ID distribution must use a real identity.')
frameworks = app / 'Contents/Frameworks' 
resources = app / 'Contents/Resources'
frameworks.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
def run(*args):
    return subprocess.check_output(args, text=True)
def dependencies(path):
    return [line.strip().split(' (compatibility')[0] for line in run('otool', '-L', str(path)).splitlines()[1:]]

pending = [prefix / 'lib' / name for name in ('libssh2.1.dylib', 'libfreerdp3.3.dylib', 'libfreerdp-client3.3.dylib', 'libwinpr3.3.dylib')]
sources = {}
while pending:
    source = pending.pop()
    if source.name in sources:
        continue
    if not source.exists():
        raise SystemExit(f'Missing native library: {source}. Run scripts/prepare-dependencies.sh first.')
    sources[source.name] = source
    for dependency in dependencies(source):
        if dependency.startswith(('/System/', '/usr/lib/', '@rpath/', '@loader_path/')):
            continue
        candidate = Path(dependency)
        if candidate.resolve() == source.resolve():
            continue
        if not candidate.is_absolute():
            raise SystemExit(f'Unresolved library dependency: {dependency}')
        pending.append(candidate)
for name, source in sources.items():
    destination = frameworks / name
    shutil.copy2(source.resolve(), destination)
    destination.chmod(0o755)
    subprocess.run(['install_name_tool', '-id', '@rpath/' + name, str(destination)], check=True)
    for dependency in dependencies(source):
        if Path(dependency).name in sources:
            subprocess.run(['install_name_tool', '-change', dependency, '@rpath/' + Path(dependency).name, str(destination)], check=True)
    subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(destination)], check=True)
for executable in (app / 'Contents/MacOS').iterdir():
    if not executable.is_file():
        continue
    for dependency in dependencies(executable):
        if Path(dependency).name in sources:
            subprocess.run(['install_name_tool', '-change', dependency, '@rpath/' + Path(dependency).name, str(executable)], check=True)
helper_source = prefix / 'bin' / 'FarcastWireGuard'
if not helper_source.is_file():
    raise SystemExit('Missing embedded WireGuard helper. Run scripts/prepare-wireguard.sh first.')
helper = app / 'Contents/MacOS/FarcastWireGuard'
shutil.copy2(helper_source, helper)
helper.chmod(0o755)
helper_signing = ['codesign', '--force', '--sign', identity, '--identifier', 'com.peterpo.farcast.wireguard', '--timestamp=none']
if os.environ.get('ENABLE_HARDENED_RUNTIME') == 'YES':
    helper_signing += ['--options', 'runtime']
helper_entitlements = Path(__file__).resolve().parent.parent / 'Configuration/WireGuardHelper.entitlements'
subprocess.run(helper_signing + ['--entitlements', str(helper_entitlements), str(helper)], check=True)
project_root = Path(__file__).resolve().parent.parent
bridge = app / 'Contents/MacOS/FarcastRsync'
subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-mmacosx-version-min=27.0', '-O2',
                str(project_root / 'Helpers/Rsync/bridge.c'), '-o', str(bridge)], check=True)
bridge_signing = ['com.peterpo.farcast.rsync' if value == 'com.peterpo.farcast.wireguard' else value for value in helper_signing]
subprocess.run(bridge_signing + ['--entitlements', str(helper_entitlements), str(bridge)], check=True)
shutil.copyfile(project_root / 'LICENSE', resources / 'LICENSE')
shutil.copyfile(project_root / 'CHANGELOG.md', resources / 'CHANGELOG.md')
license_root = project_root / 'ThirdParty'
if license_root.exists():
    bundled_licenses = resources / 'ThirdParty'
    shutil.rmtree(bundled_licenses, ignore_errors=True)
    shutil.copytree(license_root, bundled_licenses)
rsync_cache = project_root / '.dependencies/rsync'
rsync_binary = app / 'Contents/MacOS/rsync'
shutil.copy2(rsync_cache / 'rsync', rsync_binary)
rsync_signing = ['com.peterpo.farcast.bundled-rsync' if value == 'com.peterpo.farcast.wireguard' else value for value in helper_signing]
subprocess.run(rsync_signing + ['--entitlements', str(helper_entitlements), str(rsync_binary)], check=True)
source_dir = resources / 'ThirdParty/rsync-source'
source_dir.mkdir(exist_ok=True)
shutil.copy2(rsync_cache / 'rsync-3.5.2.tar.gz', source_dir)
shutil.copy2(project_root / 'scripts/prepare-rsync.sh', source_dir)
for name in sources:
    for dependency in dependencies(frameworks / name):
        if dependency.startswith(('/opt/', '/Users/', '/private/')):
            raise SystemExit(f'Unbundled dependency in {name}: {dependency}')
print(f'Bundled {len(sources)} native libraries.')
