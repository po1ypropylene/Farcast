import AppKit
import Combine
import CryptoKit
import SwiftData
import SwiftUI

/// Retained scopes belong to the selected library and key, never to protocol sessions.
enum ConnectionStorageAccess {
    private static var scopes: [URL] = []
    static func restore(_ name: String, defaults: UserDefaults = .standard) throws -> URL? {
        guard let data = defaults.data(forKey: name + "Bookmark") else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw ConnectionStorageError.invalid }
        scopes.append(url)
        if stale { try remember(url, name: name, defaults: defaults) }
        return url
    }
    static func remember(_ url: URL, name: String, defaults: UserDefaults = .standard) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: name + "Bookmark")
    }
    static func root(defaults: UserDefaults = .standard) throws -> URL? {
        guard let scope = try restore("connectionStorage", defaults: defaults) else { return nil }
        let path = defaults.string(forKey: "connectionStoragePath") ?? scope.path
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard
            root.path == scope.standardizedFileURL.path
                || root.deletingLastPathComponent().path == scope.standardizedFileURL.path
        else { throw ConnectionStorageError.invalid }
        if try ConnectionStorage.manifest(at: root).protection == .keyFile {
            _ = try restore("connectionStorageKey", defaults: defaults)
        }
        return root
    }
    static func chooseRoot(useDefault: Bool) throws -> (URL, URL)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = ConnectionStorage.realHome
        panel.message =
            useDefault
            ? "Select your home folder to authorize ~/.farcast-connections."
            : "Choose a connection library folder. Migration is offered when you apply the change."
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        let root = useDefault ? selected.appendingPathComponent(".farcast-connections") : selected
        return (root, selected)
    }
    static func chooseKey(generate: Bool, filename: String = ".farcast-key") throws -> URL? {
        let url: URL
        if generate {
            guard !filename.isEmpty, ![".", ".."].contains(filename), !filename.contains("/"), !filename.contains("\0")
            else {
                throw ConnectionStorageError.invalid
            }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = ConnectionStorage.realHome
            panel.message =
                "Choose the folder for the new key named \(filename). Existing files will not be overwritten. Keep a separate backup."
            guard panel.runModal() == .OK, let selected = panel.url else { return nil }
            url = selected.appendingPathComponent(filename)
            // A directory grant permits secure temporary-file creation and atomic publication.
            try StorageFile.write(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }, to: url, replace: false)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = ConnectionStorage.realHome
            panel.message = "Select an existing raw 16-byte AES-128 key file."
            guard panel.runModal() == .OK, let selected = panel.url else { return nil }
            url = selected
        }
        guard try StorageFile.read(url, limit: 16).count == 16 else { throw ConnectionStorageError.invalid }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

@MainActor final class ConnectionStorageController: ObservableObject {
    static let shared = ConnectionStorageController()
    @Published var container: ModelContainer?
    @Published var revision = UUID()
    @Published var startupError = ""
    @Published var needsPassword = false
    private let defaults: UserDefaults
    private let legacyCredentialRoot: URL
    var hasLocalFallbackCredentials: Bool {
        guard container != nil, storage == nil,
            let names = try? FileManager.default.contentsOfDirectory(atPath: legacyCredentialRoot.path)
        else { return false }
        return names.contains { $0.hasSuffix(".json") && UUID(uuidString: String($0.dropLast(5))) != nil }
    }
    init(
        defaults: UserDefaults = .standard, container: ModelContainer? = nil, storage: ConnectionStorage? = nil,
        legacyCredentialRoot: URL = LegacyCredentialStore.legacyRoot
    ) {
        self.defaults = defaults
        self.legacyCredentialRoot = legacyCredentialRoot
        self.container = container
        self.storage = storage
    }
    @Published private(set) var storage: ConnectionStorage?
    weak var settingsDraft: ConnectionStorageDraft?
    weak var workspace: Workspace?
    var canChangeStorage: Bool {
        guard let workspace else { return true }
        return workspace.sessions.isEmpty && workspace.editor == nil && !workspace.showWireGuard
            && !workspace.showLibraryImport && workspace.testServerImport == nil
    }

    func start(password: String = "") {
        guard container == nil else { return }
        do {
            if defaults.bool(forKey: "useConnectionStorageFolder") {
                guard let root = try ConnectionStorageAccess.root(defaults: defaults) else {
                    throw ConnectionStorageError.invalid
                }
                if try ConnectionStorage.manifest(at: root).protection == .password, password.isEmpty {
                    needsPassword = true
                    return
                }
                storage = try ConnectionStorage.open(root, password: password)
                container = try Self.folderContainer(root)
            } else {
                storage = nil
                container = try ModelContainer(for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self)
            }
            ConnectionStorageSession.use(storage)
            startupError = ""
            needsPassword = false
        } catch {
            startupError =
                "The connection library could not be opened. Check folder access, password and the original key file. No library was reset."
        }
    }
    static func folderContainer(_ root: URL) throws -> ModelContainer {
        try StorageFile.directory(root)
        for suffix in ["", "-wal", "-shm"] {
            let file = root.appendingPathComponent("default.store" + suffix)
            if FileManager.default.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    throw ConnectionStorageError.invalid
                }
            }
        }
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, url: root.appendingPathComponent("default.store")))
        for suffix in ["", "-wal", "-shm"] {
            let path = root.appendingPathComponent("default.store" + suffix).path
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        return container
    }

    func apply(
        folderMode: Bool, root: URL, scope: URL?, protection: CredentialProtection,
        keyFile: URL, password: String, migrate: Bool
    ) throws {
        guard canChangeStorage, !migrate || container != nil else {
            throw ConnectionStorageError.locked
        }
        let preferenceNames = ["connectionStorageBookmark", "connectionStorageKeyBookmark"]
        let previous = preferenceNames.map { defaults.object(forKey: $0) }
        var committed = false
        defer {
            if !committed {
                for (name, value) in zip(preferenceNames, previous) {
                    if let value {
                        defaults.set(value, forKey: name)
                    } else {
                        defaults.removeObject(forKey: name)
                    }
                }
            }
        }
        if folderMode, storage?.root.standardizedFileURL.path == root.standardizedFileURL.path {
            if protection == .keyFile {
                try ConnectionStorageAccess.remember(keyFile, name: "connectionStorageKey", defaults: defaults)
            }
            try ConnectionStorageSession.changeProtection(protection, keyFile: keyFile, password: password)
            storage = try ConnectionStorageSession.withStorage { $0 }
            if protection != .keyFile { defaults.removeObject(forKey: "connectionStorageKeyBookmark") }
            committed = true
            return
        }
        if !folderMode, storage == nil, container != nil {
            committed = true
            return
        }
        try container?.mainContext.save()
        let nextStorage: ConnectionStorage?
        let target: ModelContainer
        if folderMode {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("storage.json").path) {
                nextStorage = try ConnectionStorage.open(root, password: password)
                // Existing libraries retain their own encryption choice until opened.
            } else {
                if FileManager.default.fileExists(atPath: root.path),
                    try !FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
                {
                    throw ConnectionStorageError.exists
                }
                nextStorage = try ConnectionStorage.create(
                    root, protection: protection, keyFile: keyFile, password: password)
            }
            target = try Self.folderContainer(root)
        } else {
            nextStorage = nil
            target = try ModelContainer(for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self)
        }
        let targetLoad: (UUID) throws -> ConnectionCredential? = { id in
            if let nextStorage { return try nextStorage.credentials.load(id) }
            return try LegacyCredentialStore.loadForMigration(id)
        }
        let targetSave: (ConnectionCredential, UUID) throws -> Void = { credential, id in
            if let nextStorage {
                try nextStorage.credentials.save(credential, for: id)
            } else {
                try LegacyCredentialStore.save(credential, for: id)
            }
        }
        let targetDelete: (UUID) throws -> Void = { id in
            if let nextStorage { try nextStorage.credentials.delete(id) } else { try LegacyCredentialStore.delete(id) }
        }
        // Resolve bookmarks before writing migrated data or committing the selected library.
        if folderMode {
            try ConnectionStorageAccess.remember(scope ?? root, name: "connectionStorage", defaults: defaults)
            if let key = nextStorage?.manifest.keyFile {
                try ConnectionStorageAccess.remember(
                    URL(fileURLWithPath: key), name: "connectionStorageKey", defaults: defaults)
            }
        }
        if migrate, let container {
            try ConnectionLibraryMigration.copy(
                from: container.mainContext, to: target.mainContext, load: CredentialStore.loadForMigration,
                targetLoad: targetLoad, save: targetSave, delete: targetDelete)
        }
        defaults.set(folderMode, forKey: "useConnectionStorageFolder")
        if folderMode { defaults.set(root.path, forKey: "connectionStoragePath") }
        if nextStorage?.manifest.protection != .keyFile {
            defaults.removeObject(forKey: "connectionStorageKeyBookmark")
        }
        storage = nextStorage
        ConnectionStorageSession.use(nextStorage)
        workspace?.modelContext = nil
        workspace?.editor = nil
        workspace?.selectedSessionID = nil
        self.container = target
        defaults.removeObject(forKey: "workspaceConnections")
        startupError = ""
        needsPassword = false
        revision = UUID()
        committed = true
    }
}

struct ConnectionStorageWorkspace: View {
    @ObservedObject var workspace: Workspace
    let ready: () -> Void
    @ObservedObject private var controller = ConnectionStorageController.shared
    @State private var password = ""
    var body: some View {
        Group {
            if let container = controller.container {
                WorkspaceView(workspace: workspace).modelContainer(container).id(controller.revision).onAppear(
                    perform: ready)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(controller.needsPassword ? "Unlock Connection Library" : "Connection Library").font(.title2)
                    if controller.needsPassword { SecureField("Library password", text: $password) }
                    if !controller.startupError.isEmpty { Text(controller.startupError).foregroundStyle(.red) }
                    Button(controller.needsPassword ? "Unlock" : "Retry") {
                        controller.start(password: password)
                        password = ""
                    }.keyboardShortcut(.defaultAction)
                    SettingsLink { Text("Storage Settings…") }
                }.padding(28).frame(width: 540)
            }
        }.task {
            controller.workspace = workspace
            controller.start()
        }
    }
}
