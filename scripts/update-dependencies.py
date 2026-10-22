#!/usr/bin/env python3
"""Preview or apply upstream dependency pins; optionally rebuild the app."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
PREPARE = ROOT / 'scripts/prepare-dependencies.sh'
PROJECT = ROOT / 'Farcast.xcodeproj/project.pbxproj'
RESOLVED = ROOT / 'Farcast.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
GO = ROOT / 'Networking/VPN'
NATIVE = {
    'openssl': ('OpenSSL', 'https://github.com/openssl/openssl.git', 'openssl-'),
    'libssh2': ('libssh2', 'https://github.com/libssh2/libssh2.git', 'libssh2-'),
    'freerdp': ('FreeRDP', 'https://github.com/FreeRDP/FreeRDP.git', ''),
}
SWIFT_URL = 'https://github.com/migueldeicaza/SwiftTerm'


def run(arguments, cwd=ROOT, env=None):
    try:
        return subprocess.check_output(arguments, cwd=cwd, env=env, text=True).strip()
    except subprocess.CalledProcessError as error:
        # Preserve resolver diagnostics so failures do not show only an exit code.
        if error.output:
            print(error.output)
        raise


def semantic_version(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise RuntimeError('Native/SwiftTerm versions must be stable x.y.z releases.')
    return tuple(map(int, version.split('.')))


def master_pin(url):
    lines = run(['git', 'ls-remote', url, 'refs/heads/master']).splitlines()
    if len(lines) != 1 or not re.fullmatch(r'[0-9a-f]{40}\trefs/heads/master', lines[0]):
        raise RuntimeError('Cannot resolve unique libssh2 master revision.')
    return lines[0].split('\t')[0]


def tag_pin(url, prefix, version, current):
    refs = {}
    for line in run(['git', 'ls-remote', '--tags', url]).splitlines():
        revision, ref = line.split('\t')
        refs[ref.removeprefix('refs/tags/')] = revision
    releases = {}
    for tag in refs:
        if tag.endswith('^{}') or not tag.startswith(prefix):
            continue
        number = tag[len(prefix):]
        if not prefix:
            number = number.removeprefix('v').removeprefix('V')
        if not re.fullmatch(r'\d+\.\d+\.\d+', number):
            continue
        commit = refs.get(tag + '^{}', refs[tag])
        if number in releases and releases[number] != commit:
            raise RuntimeError(f'Ambiguous upstream tags for release {number}.')
        releases[number] = commit
    if version == 'latest':
        versions = [number for number in releases
                    if semantic_version(number)[0] == semantic_version(current)[0]]
        if not versions:
            raise RuntimeError('No stable release tags found in the current major version.')
        version = max(versions, key=semantic_version)
    if semantic_version(version) < semantic_version(current):
        raise RuntimeError(f'Refusing dependency downgrade from {current} to {version}.')
    if version not in releases:
        raise RuntimeError(f'Upstream release tag not found: {prefix}{version}')
    return version, releases[version]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--latest', action='store_true', help='Select current-major stable releases, libssh2 master and latest WireGuard.')
    for name in (*NATIVE, 'swiftterm', 'wireguard'):
        parser.add_argument('--' + name, metavar='VERSION', help='Select only this dependency (or use latest).')
    parser.add_argument('--apply', action='store_true', help='Write pins, resolve Swift/Go checksums and invalidate generated libraries.')
    parser.add_argument('--build', action='store_true', help='Run scripts/build.sh after applying pins.')
    args = parser.parse_args()
    if args.build and not args.apply:
        parser.error('--build requires --apply')
    selected = {name: getattr(args, name) or ('latest' if args.latest else None)
                for name in (*NATIVE, 'swiftterm', 'wireguard')}
    if not any(selected.values()):
        parser.print_help()
        return
    # Validate parents before upstream tools can write caches or manifests.
    for path in (PREPARE, PROJECT, RESOLVED, GO / "go.mod", GO / "go.sum",
                 ROOT / ".dependencies/go/modules", ROOT / ".dependencies/go/build",
                 ROOT / ".dependencies/sources", ROOT / ".dependencies/build",
                 ROOT / ".dependencies/swift-packages", ROOT / "Vendor/Native/bin/FarcastWireGuard",
                 ROOT / "ThirdParty/README.md", ROOT / "ThirdParty/WireGuard-build-modules.txt"):
        for ancestor in [path, *path.parents]:
            if ancestor == ROOT:
                break
            if ancestor.is_symlink():
                raise RuntimeError("Refusing dependency update through a symbolic-link path.")
    prepare = PREPARE.read_text()
    project = PROJECT.read_text()
    notices = (ROOT / 'ThirdParty/README.md').read_text()
    updated_native = False
    for key, (name, url, prefix) in NATIVE.items():
        if not selected[key]:
            continue
        pattern = rf'^fetch {name} {re.escape(url)} (\S+) ([0-9a-f]{{40}})$'
        match = re.search(pattern, prepare, re.MULTILINE)
        if not match:
            raise RuntimeError(f'Cannot locate unique {name} build pin.')
        old_version = match[1][len(prefix):]
        if key == 'libssh2':
            if selected[key] not in ('latest', 'master'):
                raise RuntimeError('libssh2 uses patched master; select --libssh2 master (or latest).')
            version, revision = 'master', master_pin(url)
            ref = version
            display_version = f'master `{revision}`'
            old_version = match[1]
        else:
            version, revision = tag_pin(url, prefix, selected[key], old_version)
            ref = prefix + version
            display_version = version
        print(f'{name}: {old_version} -> {version} ({revision})')
        updated_native |= (ref, revision) != match.groups()
        prepare = prepare.replace(match[0], f'fetch {name} {url} {ref} {revision}', 1)
        label = 'FreeRDP / WinPR' if key == 'freerdp' else name
        notices = re.sub(rf'(\| {re.escape(label)} \| )[^|]+', rf'\g<1>{display_version} ', notices)
    if selected['swiftterm']:
        pattern = r'(repositoryURL = "https://github.com/migueldeicaza/SwiftTerm"; requirement = \{kind = exactVersion; version = )(\d+\.\d+\.\d+)(; \};)'
        match = re.search(pattern, project)
        if not match:
            raise RuntimeError('Cannot locate SwiftTerm exact-version requirement.')
        version, revision = tag_pin(SWIFT_URL, '', selected['swiftterm'], match[2])
        print(f'SwiftTerm: {match[2]} -> {version} ({revision})')
        project = re.sub(pattern, lambda m: m[1] + version + m[3], project)
        notices = re.sub(r'(\| SwiftTerm \| )[^|]+', rf'\g<1>{version} ', notices)
    env = os.environ.copy()
    env.update(GOCACHE=str(ROOT / '.dependencies/go/build'), GOMODCACHE=str(ROOT / '.dependencies/go/modules'))
    wg_version = None
    if selected['wireguard']:
        requested = selected['wireguard']
        if not re.fullmatch(r'[A-Za-z0-9.+_-]+', requested):
            raise RuntimeError('Invalid WireGuard module version/revision.')
        info = json.loads(run(['go', 'list', '-m', '-json',
                               'golang.zx2c4.com/wireguard@' + requested], GO, env))
        wg_version = info['Version']
        print(f'WireGuard: -> {wg_version}; transitive modules resolved by Go (no independent gVisor upgrade).')
    if not args.apply:
        print('Preview only (upstream queries may populate .dependencies caches). Use --apply to write pins.')
        return
    # Preflight deletion before any mutation. Never erase tracked or redirected outputs.
    spec = importlib.util.spec_from_file_location('clean_project', ROOT / 'scripts/clean-project.py')
    cleaner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cleaner)
    invalidated = []
    if updated_native:
        invalidated = [ROOT / relative for relative in (
            '.dependencies/sources', '.dependencies/build',
            '.dependencies/rdp-fixture', 'Vendor/Native')]
    elif wg_version:
        invalidated = [ROOT / 'Vendor/Native/bin/FarcastWireGuard']
    cleaner.validate_targets(ROOT, invalidated)
    files = [PREPARE, PROJECT, RESOLVED, GO / 'go.mod', GO / 'go.sum',
             ROOT / 'ThirdParty/README.md', ROOT / 'ThirdParty/WireGuard-build-modules.txt']
    if any(path.is_symlink() for path in files):
        raise RuntimeError('Refusing to update symlinked pin files.')
    backup = {path: path.read_bytes() if path.exists() else None for path in files}
    try:
        PREPARE.write_text(prepare)
        PROJECT.write_text(project)
        if wg_version:
            run(['go', 'get', 'golang.zx2c4.com/wireguard@' + wg_version], GO, env)
            run(['go', 'mod', 'tidy'], GO, env)
            run(['go', 'mod', 'verify'], GO, env)
            inventory = run(['go', 'list', '-m', 'all'], GO, env)
            (ROOT / 'ThirdParty/WireGuard-build-modules.txt').write_text(inventory + '\n')
            versions = dict(line.split() for line in inventory.splitlines()[1:])
            labels = {'wireguard-go': 'golang.zx2c4.com/wireguard', 'gVisor netstack': 'gvisor.dev/gvisor',
                      'google/btree': 'github.com/google/btree'}
            for label in ('golang.org/x/crypto', 'golang.org/x/net', 'golang.org/x/sys', 'golang.org/x/time'):
                labels[label] = label
            for label, module in labels.items():
                if module in versions:
                    notices = re.sub(rf'(\| {re.escape(label)} \| )[^|]+',
                                     lambda m: m[1] + versions[module] + ' ', notices)
        if selected['swiftterm']:
            run(['xcodebuild', '-resolvePackageDependencies', '-project', 'Farcast.xcodeproj',
                 '-scheme', 'Farcast', '-derivedDataPath', '.build/Xcode',
                 '-clonedSourcePackagesDirPath', '.dependencies/swift-packages',
                 '-skipPackagePluginValidation'])
            pins = json.loads(RESOLVED.read_text())['pins']
            pin = next(item for item in pins if item['identity'] == 'swiftterm')
            if pin['state']['version'] != version or pin['state']['revision'] != revision:
                raise RuntimeError('SwiftTerm resolution does not match the selected upstream tag.')
        (ROOT / 'ThirdParty/README.md').write_text(notices)
    except BaseException:
        for path, content in backup.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(content)
        print('Pin/manifest changes rolled back; downloaded caches may remain.')
        raise
    # Force regeneration; otherwise build.sh could reuse libraries from the old pins.
    for path in invalidated:
        cleaner.remove(path)
    print('Pins updated. Review the diff and upstream license/NOTICE changes in ThirdParty before distribution.')
    print('Run scripts/build.sh and the verification commands in AGENTS.md. No compatibility pass is implied.')
    if args.build:
        # Build errors leave the successfully resolved pins available for inspection/fixing.
        subprocess.run(['scripts/build.sh'], cwd=ROOT, check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError, StopIteration) as error:
        raise SystemExit(f'Dependency update failed: {error}')
