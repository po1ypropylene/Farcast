import Foundation
import SwiftData

@main struct MigrationCheck {
    @MainActor static func main() throws {
        let store = URL(fileURLWithPath: CommandLine.arguments[1])
        #if BASELINE
            let schema = Schema([SavedConnection.self, ConnectionFolder.self])
        #else
            let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        #endif
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: store))
        #if BASELINE
            var draft = ConnectionDraft()
            draft.name = "Synthetic existing RDP"
            draft.host = "private.example"
            draft.username = "fixture"
            draft.kind = .rdp
            draft.port = 3389
            draft.clipboard = true
            draft.audioPlayback = false
            draft.favorite = true
            let folder = ConnectionFolder(name: "Synthetic existing folder")
            draft.folderID = folder.id
            container.mainContext.insert(folder)
            container.mainContext.insert(SavedConnection(draft: draft))
            try container.mainContext.save()
        #else
            let connections = try container.mainContext.fetch(FetchDescriptor<SavedConnection>())
            let folders = try container.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
            guard connections.count == 1, folders.count == 1, let saved = connections.first,
                saved.name == "Synthetic existing RDP", saved.host == "private.example", saved.username == "fixture",
                saved.kind == .rdp, saved.port == 3389, saved.clipboard, !saved.audioPlayback, saved.favorite,
                saved.folderID == folders[0].id
            else { throw WireGuardError.unavailable }
            if CommandLine.arguments.count == 2 {
                guard saved.wireGuardID == nil, saved.rdpDisplayMode == nil, saved.rdpFolderExports == nil,
                    saved.sshForwardingRules == nil, ConnectionDraft(saved).forwardingRules.isEmpty,
                    !ConnectionDraft(saved).forwardingRulesUnavailable,
                    ConnectionDraft(saved).redirectedFolders.isEmpty, ConnectionDraft(saved).displayMode == .fit
                else { throw WireGuardError.unavailable }
                let tunnel = try SavedWireGuard(
                    name: "Synthetic migrated tunnel", configuration: WireGuardConfiguration())
                container.mainContext.insert(tunnel)
                saved.wireGuardID = tunnel.id
                saved.rdpDisplayMode = RDPDisplayMode.actualSize.rawValue
                saved.rdpFolderExports = try JSONEncoder().encode([
                    RDPFolderExport(name: "Migrated files", bookmark: Data([1, 2, 3]), readOnly: true)
                ])
                saved.sshForwardingRules = try JSONEncoder().encode([SSHForwardingRule(kind: .socks)])
                try container.mainContext.save()
                print("PASS existing SwiftData library migrated with profiles/folders/settings preserved")
            } else {
                let tunnels = try container.mainContext.fetch(FetchDescriptor<SavedWireGuard>())
                guard tunnels.count == 1, saved.wireGuardID == tunnels[0].id,
                    ConnectionDraft(saved).forwardingRules.count == 1,
                    ConnectionDraft(saved).forwardingRules[0].kind == .socks,
                    ConnectionDraft(saved).displayMode == .actualSize,
                    ConnectionDraft(saved).redirectedFolders == [
                        RDPFolderExport(
                            id: ConnectionDraft(saved).redirectedFolders.first!.id, name: "Migrated files",
                            bookmark: Data([1, 2, 3]), readOnly: true)
                    ]
                else { throw WireGuardError.unavailable }
                print(
                    "PASS migrated library reopened with saved WireGuard, RDP display and redirected-folder selections")
            }
        #endif
    }
}
