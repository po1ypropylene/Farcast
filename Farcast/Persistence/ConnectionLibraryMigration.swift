import Foundation
import SwiftData

/// Copies live metadata through SwiftData, so WAL state is included without opening/copying the source database.
/// Call only with no session tabs. Sources (including Keychain records) are never deleted.
@MainActor enum ConnectionLibraryMigration {
    static func copy(
        from source: ModelContext, to destination: ModelContext,
        load: (UUID) throws -> ConnectionCredential?,
        targetLoad: (UUID) throws -> ConnectionCredential?,
        save: (ConnectionCredential, UUID) throws -> Void,
        delete: (UUID) throws -> Void
    ) throws {
        guard try destination.fetchCount(FetchDescriptor<SavedConnection>()) == 0,
            try destination.fetchCount(FetchDescriptor<ConnectionFolder>()) == 0,
            try destination.fetchCount(FetchDescriptor<SavedWireGuard>()) == 0
        else { throw ConnectionStorageError.exists }
        try source.save()
        let profiles = try source.fetch(FetchDescriptor<SavedConnection>())
        let folders = try source.fetch(FetchDescriptor<ConnectionFolder>())
        let tunnels = try source.fetch(FetchDescriptor<SavedWireGuard>())
        var credentials: [UUID: ConnectionCredential] = [:]
        for id in Set(profiles.map(\.id) + tunnels.map(\.id)) {
            guard try targetLoad(id) == nil else { throw ConnectionStorageError.exists }
            if let credential = try load(id) { credentials[id] = credential }
        }
        let previousAutosave = destination.autosaveEnabled
        destination.autosaveEnabled = false
        defer { destination.autosaveEnabled = previousAutosave }
        var written: [UUID] = []
        do {
            for folder in folders {
                let copy = ConnectionFolder(name: folder.name, order: folder.order)
                copy.id = folder.id
                copy.parentID = folder.parentID
                copy.isCollapsed = folder.isCollapsed
                destination.insert(copy)
            }
            for profile in profiles {
                let copy = SavedConnection(draft: ConnectionDraft(profile))
                copy.protocolName = profile.protocolName
                copy.authentication = profile.authentication
                copy.rdpDisplayMode = profile.rdpDisplayMode
                copy.vncRemoteIsMac = profile.vncRemoteIsMac
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
            for (id, credential) in credentials {
                try save(credential, id)
                written.append(id)
            }
            try destination.save()
        } catch {
            destination.rollback()
            for id in written { try? delete(id) }
            throw error
        }
    }
}
