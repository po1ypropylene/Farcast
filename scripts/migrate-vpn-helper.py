#!/usr/bin/env python3
"""One-time source-checkout migration from Networking/WireGuard to Networking/VPN.

Installed apps need no data migration. Run with builds stopped; review and commit
the resulting source changes. Never reads app libraries, credentials or caches.
"""
import argparse
from pathlib import Path


REFERENCES = (
    'scripts/prepare-wireguard.sh',
    'scripts/test-wireguard.sh',
    'scripts/test-wireguard-sessions.sh',
    'scripts/update-dependencies.py',
    'Tests/Maintenance/test_maintenance.py',
    'docs/architecture.md',
    'docs/branding.md',
    'ThirdParty/WireGuard-build-modules.txt',
    'Networking/WireGuard/go.mod',
)


def migrate(root):
    old = root / 'Networking/WireGuard'
    new = root / 'Networking/VPN'
    # Validate every path before moving or writing anything. Never merge two trees.
    for relative in (*REFERENCES, 'Networking/VPN'):
        path = root / relative
        while path != root:
            if path.is_symlink():
                raise RuntimeError('Refusing a symbolic-link migration path.')
            path = path.parent
    if not old.exists():
        if new.is_dir():
            return False
        raise RuntimeError('No VPN helper source directory found.')
    if not old.is_dir() or new.exists():
        raise RuntimeError('Refusing to replace or merge helper source directories.')
    updates = {}
    for relative in REFERENCES:
        path = root / relative
        if path.exists():
            original = path.read_text()
            updated = original.replace('Networking/WireGuard', 'Networking/VPN').replace(
                'com.peterpo.farcast/wireguard', 'com.peterpo.farcast/vpn')
            if updated != original:
                target = new / path.relative_to(old) if path.is_relative_to(old) else path
                updates[target] = updated
    old.rename(new)
    for path, content in updates.items():
        path.write_text(content)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent,
                        help='Older source checkout to migrate (default: this checkout).')
    args = parser.parse_args()
    try:
        changed = migrate(args.root.resolve())
    except (OSError, UnicodeError, RuntimeError):
        raise SystemExit('Migration failed; check source directories and permissions. No trees are merged.')
    print('Migrated VPN helper source paths; review the diff and rebuild.' if changed
          else 'VPN helper source paths are already migrated; no changes.')


if __name__ == '__main__':
    main()
