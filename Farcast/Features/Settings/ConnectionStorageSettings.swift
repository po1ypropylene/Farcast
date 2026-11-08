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
    init(defaults: UserDefaults = .standard, container: ModelContainer? = nil, storage: ConnectionStorage? = nil) {
        self.defaults = defaults
        self.container = container
        self.storage = storage
    }
    private(set) var storage: ConnectionStorage?
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

struct ConnectionStorageSettings: View {
    @ObservedObject var controller = ConnectionStorageController.shared
    @State private var folderMode = false
    @State private var root = ConnectionStorage.defaultRoot
    @State private var scope: URL?
    @State private var protection = CredentialProtection.keyFile
    @State private var keyFile = ConnectionStorage.defaultKey
    @State private var password = ""
    @State private var confirmation = ""
    @State private var message = ""
    @State private var confirmMigration = false
    @State private var confirmProtection = false
    @State private var keyAuthorized = false
    @State private var newKeyName = ".farcast-key"
    var body: some View {
        FormSection(title: "Connection Storage") {
            Picker("Storage", selection: $folderMode) {
                Text("App library + Keychain / local fallback").tag(false)
                Text("Custom folder").tag(true)
            }
            if folderMode {
                Text(root.path).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Default Folder…") { choose(defaultFolder: true) }
                    Button("Choose Folder…") { choose(defaultFolder: false) }
                }
                Picker("Credential protection", selection: $protection) {
                    ForEach(CredentialProtection.allCases) { Text($0.title).tag($0) }
                }
                if protection == .keyFile {
                    Text(keyFile.path).font(.caption).textSelection(.enabled)
                    TextField("New key filename", text: $newKeyName).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Generate New Key…") { chooseKey(generate: true) }
                        Button("Use Existing Key…") { chooseKey(generate: false) }
                    }
                }
                if protection == .password {
                    SecureField("Library password", text: $password)
                    SecureField("Confirm password (new library or protection)", text: $confirmation)
                }
                Text(
                    protection == .unencrypted
                        ? "Credentials are unencrypted local files, readable by anyone with folder access."
                        : "AES-128-GCM protects credentials. Connection metadata is unencrypted. Back up the key or password separately; neither can be recovered if lost."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(
                    "Connection metadata stays in the app library. Credentials use Keychain when available, with an owner-only, unencrypted local fallback."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "Close all session tabs and connection/import editors before changing storage. Migration copies data and preserves the source; it requires an empty destination."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Apply Storage…") {
                guard controller.canChangeStorage else {
                    message = "Close all session tabs and connection/import editors before changing storage."
                    return
                }
                do {
                    if folderMode, scope == nil,
                        controller.storage?.root.standardizedFileURL.path != root.standardizedFileURL.path
                    {
                        guard
                            let (selected, selectedScope) = try ConnectionStorageAccess.chooseRoot(
                                useDefault: root == ConnectionStorage.defaultRoot)
                        else { return }
                        root = selected
                        scope = selectedScope
                    }
                    if folderMode, protection == .keyFile, !keyAuthorized,
                        controller.storage?.manifest.keyFile != keyFile.path
                    {
                        message = "Generate a new key or select an existing key before applying storage."
                        return
                    }
                } catch {
                    message = "Authorize the library folder and key file before continuing."
                    return
                }
                if folderMode, controller.storage?.root.standardizedFileURL.path == root.standardizedFileURL.path {
                    confirmProtection = true
                } else {
                    confirmMigration = true
                }
            }
            if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
        }.onAppear { refresh() }
            .alert("Migrate connections and credentials?", isPresented: $confirmMigration) {
                Button("Migrate and Switch") { apply(migrate: true) }
                Button("Use Destination Without Migrating") { apply(migrate: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Copy all saved connections, folders, VPN profiles and their credentials to the destination. Keychain access may ask for approval. Original data is kept. Without migration, the destination’s existing library is opened, or a new empty one is created."
                )
            }
            .alert("Change credential protection?", isPresented: $confirmProtection) {
                Button("Re-encrypt Credentials") { apply(migrate: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "All credentials in this library will use the selected protection. Superseded credential files will be removed after the change succeeds. Backups may retain older copies."
                )
            }
    }
    private func refresh() {
        folderMode = controller.storage != nil
        root = controller.storage?.root ?? ConnectionStorage.defaultRoot
        protection = controller.storage?.manifest.protection ?? .keyFile
        keyFile = controller.storage?.manifest.keyFile.map { URL(fileURLWithPath: $0) } ?? ConnectionStorage.defaultKey
    }
    private func choose(defaultFolder: Bool) {
        do {
            if let (selected, selectedScope) = try ConnectionStorageAccess.chooseRoot(useDefault: defaultFolder) {
                root = selected
                scope = selectedScope
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("storage.json").path) {
                    let manifest = try ConnectionStorage.manifest(at: root)
                    protection = manifest.protection
                    keyFile = manifest.keyFile.map { URL(fileURLWithPath: $0) } ?? ConnectionStorage.defaultKey
                }
            }
        } catch { message = "The folder could not be authorized or its manifest is invalid." }
    }
    private func chooseKey(generate: Bool) {
        do {
            if let selected = try ConnectionStorageAccess.chooseKey(generate: generate, filename: newKeyName) {
                keyFile = selected
                keyAuthorized = true
                message = ""
            }
        } catch {
            message =
                generate
                ? "The key could not be generated. Choose a new file name; existing files are never overwritten."
                : "Choose an accessible, regular file containing exactly 16 bytes."
        }
    }
    private func apply(migrate: Bool) {
        let existingDestination = FileManager.default.fileExists(
            atPath: root.appendingPathComponent("storage.json").path)
        let sameFolder = controller.storage?.root.standardizedFileURL.path == root.standardizedFileURL.path
        guard
            !folderMode || protection != .password || (existingDestination && !sameFolder)
                || (!password.isEmpty && password == confirmation)
        else {
            message = "Enter matching, nonempty passwords."
            return
        }
        do {
            try controller.apply(
                folderMode: folderMode, root: root, scope: scope, protection: protection,
                keyFile: keyFile, password: password, migrate: migrate)
            password = ""
            confirmation = ""
            refresh()
            message =
                controller.storage?.supersededFilesRemain == true
                ? "Protection updated, but superseded credential files could not be removed. They may still contain unencrypted credentials; remove the old Credentials directory before relying on encryption."
                : "Storage updated. Original migration sources are preserved."
        } catch ConnectionStorageError.exists {
            message =
                "Migration requires an empty destination without conflicting credentials. Choose another folder or use the destination without migrating. The original library remains active."
        } catch {
            message =
                "Storage could not be changed. Check folder and key access or the password. The original library remains active."
        }
    }
}
