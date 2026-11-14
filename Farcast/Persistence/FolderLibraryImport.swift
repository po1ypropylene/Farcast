import Foundation
import SwiftData

enum FolderLibraryImportMode: String, CaseIterable, Identifiable {
    case merge, replace
    var id: String { rawValue }
    var title: String { self == .merge ? "Merge with existing connections" : "Clear existing and import" }
}

enum FolderLibraryImportError: LocalizedError {
    case invalid, currentLibrary, empty, failed, rollbackFailed
    var errorDescription: String? {
        switch self {
        case .invalid: return "This folder could not be read as a Farcast library. Quit any app using it and try again."
        case .currentLibrary: return "That is your current library. Choose another folder."
        case .empty: return "This library has no connections or VPN profiles to import."
        case .failed: return "Import failed. Existing connections and credentials were restored."
        case .rollbackFailed:
            return
                "Import failed and some credentials could not be restored. Keep both libraries and check saved credentials before connecting."
        }
    }
}

/// Opens only a private metadata snapshot. Source credential bytes stay in memory, encrypted as supplied.
@MainActor final class FolderLibraryImport {
    let root: URL
    let manifest: ConnectionStorageManifest
    let profiles: [SavedConnection]
    let folders: [ConnectionFolder]
    let tunnels: [SavedWireGuard]
    private let container: ModelContainer
    private let staging: URL
    private let records: [UUID: Data]
    var credentialCount: Int { records.count }

    init(root: URL, currentRoot: URL?) throws {
        if let currentRoot {
            let sourceURL = root.resolvingSymlinksInPath().standardizedFileURL
            let currentURL = currentRoot.resolvingSymlinksInPath().standardizedFileURL
            let sourceID =
                try? sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
            let currentID =
                try? currentURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
                as? NSObject
            if sourceURL == currentURL || (sourceID != nil && sourceID == currentID) {
                throw FolderLibraryImportError.currentLibrary
            }
        }
        self.root = root
        staging = FileManager.default.temporaryDirectory.appendingPathComponent("Farcast-FolderImport-\(UUID())")
        do {
            manifest = try ConnectionStorage.manifest(at: root)
            try StorageFile.directory(staging)
            // Read all source files before opening SwiftData, then repeat to reject concurrent changes.
            var files: [String: Data] = [:]
            for suffix in ["", "-wal", "-shm"] {
                let name = "default.store" + suffix
                let url = root.appendingPathComponent(name)
                if suffix.isEmpty || FileManager.default.fileExists(atPath: url.path) {
                    files[name] = try ExistingLibraryImporter.readRegularFile(
                        url, beneath: root, limit: 128 * 1_024 * 1_024)
                }
            }
            for (name, data) in files {
                guard
                    try ExistingLibraryImporter.readRegularFile(
                        root.appendingPathComponent(name), beneath: root, limit: 128 * 1_024 * 1_024) == data
                else {
                    throw FolderLibraryImportError.invalid
                }
                try StorageFile.write(data, to: staging.appendingPathComponent(name))
            }
            let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
            container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: staging.appendingPathComponent("default.store"))
            )
            profiles = try container.mainContext.fetch(FetchDescriptor<SavedConnection>())
            folders = try container.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
            tunnels = try container.mainContext.fetch(FetchDescriptor<SavedWireGuard>())
            guard profiles.count + folders.count + tunnels.count <= 20_000 else {
                throw FolderLibraryImportError.invalid
            }
            guard !profiles.isEmpty || !tunnels.isEmpty else { throw FolderLibraryImportError.empty }
            var records: [UUID: Data] = [:]
            var bytes = 0
            for id in Set(profiles.map(\.id) + tunnels.map(\.id)) {
                let file = root.appendingPathComponent(manifest.credentialsDirectory).appendingPathComponent(
                    id.uuidString + ".json")
                if FileManager.default.fileExists(atPath: file.path) {
                    let data = try ExistingLibraryImporter.readRegularFile(file, beneath: root, limit: 1_048_576)
                    bytes += data.count
                    guard bytes <= 128 * 1_024 * 1_024 else { throw FolderLibraryImportError.invalid }
                    records[id] = data
                }
            }
            self.records = records
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw (error as? FolderLibraryImportError) ?? .invalid
        }
    }

    deinit { try? FileManager.default.removeItem(at: staging) }

    struct Result {
        let imported: Int
        let skipped: Int
        let credentials: Int
        let vpnProfiles: Int
    }

    /// Credential closures keep tests isolated from the user's Keychain and allow failure injection.
    func apply(
        to destination: ModelContainer, mode: FolderLibraryImportMode, unlocked: ConnectionStorage?,
        includeCredentials: Bool,
        load: (UUID) throws -> ConnectionCredential? = CredentialStore.loadForMigration,
        save: (ConnectionCredential, UUID) throws -> Void = CredentialStore.save,
        delete: (UUID) throws -> Void = CredentialStore.delete
    ) throws -> Result {
        let context = ModelContext(destination)
        context.autosaveEnabled = false
        let oldProfiles = try context.fetch(FetchDescriptor<SavedConnection>())
        let oldFolders = try context.fetch(FetchDescriptor<ConnectionFolder>())
        let oldTunnels = try context.fetch(FetchDescriptor<SavedWireGuard>())
        let existing = Set(oldProfiles.map(\.id) + oldTunnels.map(\.id))
        let incomingProfiles = profiles.filter { mode == .replace || !existing.contains($0.id) }
        let incomingTunnels = tunnels.filter { mode == .replace || !existing.contains($0.id) }
        let incomingIDs = Set(incomingProfiles.map(\.id) + incomingTunnels.map(\.id))
        var incoming: [UUID: ConnectionCredential] = [:]
        if includeCredentials {
            guard let unlocked else { throw ConnectionStorageError.locked }
            for id in incomingIDs {
                if let data = records[id] {
                    incoming[id] = try JSONDecoder().decode(
                        ConnectionCredential.self, from: unlocked.decode(data, context: id.uuidString))
                }
            }
        }
        // Stage and validate everything before clearing anything. Journal only affected credentials.
        let affected = mode == .replace ? existing.union(incomingIDs) : incomingIDs
        var previous: [UUID: ConnectionCredential] = [:]
        for id in affected {
            if let credential = try load(id) {
                if mode == .merge { throw FolderLibraryImportError.invalid }  // Preserve orphaned credentials too.
                previous[id] = credential
            }
        }
        var touched: [UUID] = []
        do {
            if mode == .replace {
                for item in oldProfiles { context.delete(item) }
                for item in oldFolders { context.delete(item) }
                for item in oldTunnels { context.delete(item) }
            }
            let folderIDs = mode == .replace ? Set<UUID>() : Set(oldFolders.map(\.id))
            for item in folders where !folderIDs.contains(item.id) {
                let copy = ConnectionFolder(name: item.name, order: item.order)
                copy.id = item.id
                copy.parentID = item.parentID
                copy.isCollapsed = item.isCollapsed
                context.insert(copy)
            }
            for item in incomingProfiles {
                let copy = SavedConnection(draft: ConnectionDraft(item))
                copy.protocolName = item.protocolName
                copy.authentication = item.authentication
                copy.rdpDisplayMode = item.rdpDisplayMode
                copy.vncRemoteIsMac = item.vncRemoteIsMac
                copy.rdpLaunchFullScreen = item.rdpLaunchFullScreen
                copy.rdpUseAllMonitors = item.rdpUseAllMonitors
                copy.rdpRetinaDisplay = item.rdpRetinaDisplay
                copy.rdpFolderExports = item.rdpFolderExports
                copy.sshForwardingRules = item.sshForwardingRules
                copy.created = item.created
                copy.lastConnected = item.lastConnected
                copy.favoriteOrder = item.favoriteOrder
                context.insert(copy)
            }
            for item in incomingTunnels {
                let copy = try SavedWireGuard(id: item.id, name: item.name, configuration: WireGuardConfiguration())
                copy.configurationData = item.configurationData
                copy.created = item.created
                context.insert(copy)
            }
            for id in affected {
                touched.append(id)
                if let credential = incoming[id] { try save(credential, id) } else { try delete(id) }
            }
            try context.save()
        } catch {
            context.rollback()
            var restored = true
            for id in touched.reversed() {
                do {
                    if let credential = previous[id] { try save(credential, id) } else { try delete(id) }
                } catch { restored = false }
            }
            throw restored ? FolderLibraryImportError.failed : .rollbackFailed
        }
        return Result(
            imported: incomingProfiles.count, skipped: profiles.count - incomingProfiles.count,
            credentials: incoming.count, vpnProfiles: incomingTunnels.count)
    }
}
