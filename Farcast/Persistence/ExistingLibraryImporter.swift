import Darwin
import Foundation
import SwiftData

enum ExistingLibraryImportError: LocalizedError {
    case nonemptyDestination, invalidSource, tooLarge
    var errorDescription: String? {
        switch self {
        case .nonemptyDestination: return "Import requires an empty Farcast library. Existing data has been preserved."
        case .invalidSource:
            return
                "The selected Library folder could not be imported. Quit the previous app and select its container’s Data/Library folder. The original library has not been changed."
        case .tooLarge:
            return "The selected library exceeds the import limits. The original library has not been changed."
        }
    }
}

/// Historical names are used only to locate user-selected migration input.
enum PreviousLibraryIdentity {
    static let bundle = "com.peterpo.UniversalRemote"
    static let credentialDirectory = "UniversalRemote/Credentials"
}

@MainActor enum ExistingLibraryImporter {
    /// The caller owns a user-selected security scope. Never open the original database:
    /// SwiftData may migrate it or create journal files even for a read-only context.
    static func importLibrary(
        from library: URL, into container: ModelContainer, includeLocalCredentials: Bool,
        credentials: LocalCredentialStore = LocalCredentialStore(), defaults: UserDefaults = .standard
    ) throws -> Int {
        let destination = ModelContext(container)
        destination.autosaveEnabled = false
        guard try destination.fetchCount(FetchDescriptor<SavedConnection>()) == 0,
            try destination.fetchCount(FetchDescriptor<ConnectionFolder>()) == 0,
            try destination.fetchCount(FetchDescriptor<SavedWireGuard>()) == 0
        else { throw ExistingLibraryImportError.nonemptyDestination }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("Farcast-Import-\(UUID())", isDirectory: true)
        try manager.createDirectory(
            at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        do {
            let sourceStore = library.appendingPathComponent("Application Support/default.store")
            let stagedStore = staging.appendingPathComponent("default.store")
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: sourceStore.path + suffix)
                if suffix.isEmpty || manager.fileExists(atPath: source.path) {
                    let data = try readRegularFile(source, beneath: library, limit: 128 * 1_024 * 1_024)
                    let target = URL(fileURLWithPath: stagedStore.path + suffix)
                    guard
                        manager.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600])
                    else { throw ExistingLibraryImportError.invalidSource }
                }
            }
            let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
            let source = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, url: stagedStore))
            let profiles = try source.mainContext.fetch(FetchDescriptor<SavedConnection>())
            let folders = try source.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
            let tunnels = try source.mainContext.fetch(FetchDescriptor<SavedWireGuard>())
            guard profiles.count + folders.count + tunnels.count <= 20_000 else {
                throw ExistingLibraryImportError.tooLarge
            }
            var importedCredentials: [UUID: ConnectionCredential] = [:]
            if includeLocalCredentials {
                let ids = Set(profiles.map(\.id) + tunnels.map(\.id))
                for id in ids {
                    let file = library.appendingPathComponent(
                        "Application Support/\(PreviousLibraryIdentity.credentialDirectory)/\(id.uuidString).json")
                    guard manager.fileExists(atPath: file.path) else { continue }
                    let data = try readRegularFile(file, beneath: library, limit: 1_048_576)
                    importedCredentials[id] = try JSONDecoder().decode(ConnectionCredential.self, from: data)
                    // Refuse to overwrite orphaned Farcast credentials as well as existing profiles.
                    guard try credentials.load(id) == nil else { throw ExistingLibraryImportError.nonemptyDestination }
                }
            }
            let settings = try readSettings(from: library)
            for folder in folders {
                let copy = ConnectionFolder(name: folder.name, order: folder.order)
                copy.id = folder.id
                copy.parentID = folder.parentID
                copy.isCollapsed = folder.isCollapsed
                destination.insert(copy)
            }
            for profile in profiles {
                let copy = SavedConnection(draft: ConnectionDraft(profile))
                // Keep raw optional/unknown values and dates, rather than normalizing older metadata.
                copy.protocolName = profile.protocolName
                copy.authentication = profile.authentication
                copy.rdpDisplayMode = profile.rdpDisplayMode
                copy.rdpLaunchFullScreen = profile.rdpLaunchFullScreen
                copy.rdpUseAllMonitors = profile.rdpUseAllMonitors
                copy.rdpRetinaDisplay = profile.rdpRetinaDisplay
                copy.rdpFolderExports = profile.rdpFolderExports
                copy.sshForwardingRules = profile.sshForwardingRules
                copy.created = profile.created
                copy.favoriteOrder = profile.favoriteOrder
                copy.lastConnected = profile.lastConnected
                destination.insert(copy)
            }
            for tunnel in tunnels {
                let copy = try SavedWireGuard(id: tunnel.id, name: tunnel.name, configuration: WireGuardConfiguration())
                copy.configurationData = tunnel.configurationData
                copy.created = tunnel.created
                destination.insert(copy)
            }
            var writtenCredentials: [UUID] = []
            do {
                for (id, credential) in importedCredentials {
                    try credentials.save(credential, for: id)
                    writtenCredentials.append(id)
                }
                try destination.save()
            } catch {
                destination.rollback()
                for id in writtenCredentials { try? credentials.delete(id) }
                throw error
            }
            for (key, value) in settings { defaults.set(value, forKey: key) }
            return profiles.count
        } catch let error as ExistingLibraryImportError {
            throw error
        } catch {
            // Never expose database paths, profile values or credential decoder diagnostics.
            throw ExistingLibraryImportError.invalidSource
        }
    }

    private static func readRegularFile(_ file: URL, beneath root: URL, limit: Int) throws -> Data {
        guard file.path.hasPrefix(root.path + "/") else { throw ExistingLibraryImportError.invalidSource }
        let components = String(file.path.dropFirst(root.path.count + 1)).split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("..") else { throw ExistingLibraryImportError.invalidSource }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ExistingLibraryImportError.invalidSource }
        defer { close(directory) }
        for component in components.dropLast() {
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw ExistingLibraryImportError.invalidSource }
            close(directory)
            directory = child
        }
        let descriptor = openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExistingLibraryImportError.invalidSource }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ExistingLibraryImportError.invalidSource
        }
        guard metadata.st_size >= 0, metadata.st_size <= limit else { throw ExistingLibraryImportError.tooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ExistingLibraryImportError.tooLarge }
        guard data.count == metadata.st_size else { throw ExistingLibraryImportError.invalidSource }
        return data
    }

    private static func readSettings(from library: URL) throws -> [String: Any] {
        let file = library.appendingPathComponent("Preferences/\(PreviousLibraryIdentity.bundle).plist")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let data = try readRegularFile(file, beneath: library, limit: 4 * 1_024 * 1_024)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ExistingLibraryImportError.invalidSource
        }
        var settings: [String: Any] = [:]
        if let appearance = values["appearance"] as? String, ["System", "Light", "Dark"].contains(appearance) {
            settings["appearance"] = appearance
        }
        if let restore = values["restoreWorkspace"] as? Bool { settings["restoreWorkspace"] = restore }
        if let tabs = values["workspaceConnections"] as? [String] {
            settings["workspaceConnections"] = tabs.filter { UUID(uuidString: $0) != nil }
        }
        if let trust = values["trustedServerIdentities"] as? [String: String] {
            settings["trustedServerIdentities"] = trust
        }
        // Security-scoped grants belong to the previous signed app. Reselect folders in Farcast.
        return settings
    }
}
