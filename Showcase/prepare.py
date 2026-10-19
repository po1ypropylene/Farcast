#!/usr/bin/env python3
"""Assemble an isolated source tree; production sources never import showcase code."""
from pathlib import Path
import json
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / '.build/showcase-source'


def validate_catalog(path):
    """Reject invalid editable input before signing, compilation or build reservation."""
    catalog = json.loads(path.read_text())
    if not isinstance(catalog, dict):
        raise ValueError('catalog must be an object')
    connections = catalog.get('connections')
    vpns = catalog.get('vpns')
    if not isinstance(connections, list) or not connections or not isinstance(vpns, list):
        raise ValueError('catalog needs a nonempty connections array and a vpns array')
    for vpn in vpns:
        if (not isinstance(vpn, dict) or
                any(not isinstance(vpn.get(key), str) for key in ['name', 'endpoint', 'address']) or
                not isinstance(vpn.get('openVPN'), bool)):
            raise ValueError('VPN profiles need name, endpoint, address and openVPN fields')
    for connection in connections:
        if (not isinstance(connection, dict) or
                any(not isinstance(connection.get(key), str) for key in ['name', 'host', 'username', 'folder']) or
                connection.get('kind') not in ['SSH', 'RDP', 'VNC'] or
                not isinstance(connection.get('favorite'), bool) or
                (connection.get('files') is not None and not isinstance(connection['files'], bool))):
            raise ValueError('connections need string metadata, SSH/RDP/VNC kind and boolean favorite/files fields')
        vpn = connection.get('vpn')
        if vpn is not None and (type(vpn) is not int or not 0 <= vpn < len(vpns)):
            raise ValueError('connection VPN index is outside the vpns array')
    sftp = catalog.get('sftp')
    if not isinstance(sftp, dict):
        raise ValueError('sftp needs independent local and remote panes')
    for side in ['local', 'remote']:
        pane = sftp.get(side)
        if (not isinstance(pane, dict) or not isinstance(pane.get('path'), str) or
                not pane['path'].startswith('/') or not isinstance(pane.get('folders'), dict) or
                pane['path'] not in pane['folders']):
            raise ValueError('each SFTP pane needs an absolute starting path and matching folders entry')
        for path, entries in pane['folders'].items():
            if not path.startswith('/') or not isinstance(entries, list):
                raise ValueError('SFTP folders need absolute paths and entry arrays')
            names = set()
            for entry in entries:
                if (not isinstance(entry, dict) or not isinstance(entry.get('name'), str) or
                        entry['name'] in ['', '.', '..'] or '/' in entry['name'] or
                        entry['name'] in names or not isinstance(entry.get('directory'), bool) or
                        type(entry.get('size')) is not int or not 0 <= entry['size'] <= 2**64 - 1):
                    raise ValueError('SFTP entries need unique filenames, boolean directory and UInt64 byte size')
                names.add(entry['name'])
    return catalog


def replace(path, old, new):
    target = DEST / path
    text = target.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f'Showcase source integration needs review: {path}: {old[:70]!r}')
    target.write_text(text.replace(old, new))


def region(path, start, end, replacement):
    target = DEST / path
    text = target.read_text()
    a = text.index(start)
    b = text.index(end, a)
    target.write_text(text[:a] + replacement + text[b:])


def prepare():
    validate_catalog(ROOT / 'Showcase/catalog.json')
    if DEST.exists():
        shutil.rmtree(DEST)
    DEST.mkdir(parents=True)
    for name in ['Farcast', 'Farcast.xcodeproj']:
        shutil.copytree(ROOT / name, DEST / name, ignore=shutil.ignore_patterns('xcuserdata'))
    for name in ['Configuration', 'Vendor', 'ThirdParty', 'scripts']:
        (DEST / name).symlink_to(ROOT / name, target_is_directory=True)
    for name in ['Version.xcconfig', 'LICENSE']:
        shutil.copy2(ROOT / name, DEST / name)
    app = 'Farcast/App/FarcastApp.swift'
    replace(app, 'container = try ModelContainer(for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self)',
            'let library = try ModelContainer(for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self, '
            'configurations: ModelConfiguration(isStoredInMemoryOnly: true))\n'
            '''            try ShowcaseLibrary.seed(library)
            if ProcessInfo.processInfo.arguments.contains("--verify-showcase") {
                try ShowcaseLibrary.verify(library)
                exit(EXIT_SUCCESS)
            }
            container = library''')
    replace(app, '            startupError = error.localizedDescription',
            '''            if ProcessInfo.processInfo.arguments.contains("--verify-showcase") {
                FileHandle.standardError.write(Data("FAIL showcase: \\(error.localizedDescription)\\n".utf8))
                exit(EXIT_FAILURE)
            }
            startupError = error.localizedDescription''')
    for name in ['ShowcaseLibrary.swift', 'ShowcaseDesktop.swift', 'catalog.json']:
        shutil.copy2(ROOT / 'Showcase' / name, DEST / 'Farcast' / name)
    session = 'Farcast/Features/Sessions/RemoteSession.swift'
    region(session, '    func start(credential: ConnectionCredential) {', '    private func startProtocol(',
           '    func start(credential: ConnectionCredential) {\n        startShowcase()\n    }\n')
    with (DEST / session).open('a') as file:
        file.write('\n' + (ROOT / 'Showcase/Session.swift').read_text())
    workspace = 'Farcast/Features/Workspace/Workspace.swift'
    region(workspace, '        if draft.kind == .ssh && draft.authentication == .interactive',
           '    private func start(_ session:', '        return ConnectionCredential()\n    }\n\n')
    replace('Farcast/Features/Workspace/WorkspaceView.swift',
            '            workspace.restoreWorkspace(connections)',
            '            workspace.restoreWorkspace(connections)\n'
            '            ShowcaseLibrary.openRequestedView(workspace: workspace, connections: connections)')
    # An ephemeral store for every credential call, including editor/VPN save/delete.
    credential = 'Farcast/Shared/Security/CredentialStore.swift'
    region(credential, 'struct CredentialStore {', '\n}', '''struct CredentialStore {
    private static var values: [UUID: ConnectionCredential] = [:]
    static func load(_ id: UUID) throws -> ConnectionCredential? {
        values[id] ?? ConnectionCredential()
    }
    static func save(_ credential: ConnectionCredential, for id: UUID) throws {
        values[id] = credential
    }
    static func delete(_ id: UUID) throws {
        values.removeValue(forKey: id)
    }''')
    files = 'Farcast/Features/Sessions/SFTPController.swift'
    region(files, '        let realHome = getpwuid', '    private func saveHomeAccess', '''        self.homeURL = URL(fileURLWithPath: ShowcaseLibrary.sftp.local.path, isDirectory: true)
        localURL = self.homeURL
        needsLocalAccess = false
        refreshLocal()
    }
''')
    region(files, '        guard !busy, let client else { return }\n        requested = true',
           '    private func recordRemoteVisit', '''        showcaseListing(path: path)
    }
''')
    region(files, '    func chooseLocalFolder() {', '    func open(_ file:', '''    func chooseLocalFolder() {
        localURL = homeURL
        refreshLocal()
    }
    func refreshLocal() {
        localFiles = ShowcaseLibrary.sftp.local.files(at: localURL?.path ?? ShowcaseLibrary.sftp.local.path)
    }
''')
    region(files, '    func open(_ file:', '    func openLocal(_ file:', '''    func open(_ file: TransferFile, local: Bool) {
        if file.directory {
            if local { openLocal(file) } else { openRemote(file) }
        }
    }
    func reveal(_ files: [TransferFile]) {}
''')
    region(files, '    private func run(_ work: [FileJob]) {', '    private func runNext()', '''    private func run(_ work: [FileJob]) {
        message = "Ready · All files up to date"
    }
''')
    with (DEST / files).open('a') as file:
        file.write('\n' + (ROOT / 'Showcase/Files.swift').read_text())
    # Separate sandbox/preferences identity; visual app and executable names stay Farcast.
    project = DEST / 'Farcast.xcodeproj/project.pbxproj'
    project.write_text(project.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.peterpo.farcast;',
                                                  'PRODUCT_BUNDLE_IDENTIFIER = com.peterpo.farcast.showcase;'))
    print(DEST)


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['--validate-catalog']:
            validate_catalog(ROOT / 'Showcase/catalog.json')
        else:
            prepare()
    except (ValueError, OSError) as error:
        raise SystemExit(f'Invalid Showcase/catalog.json: {error}')
