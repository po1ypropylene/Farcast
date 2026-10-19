import AppKit
import SwiftData

@MainActor enum ShowcaseLibrary {
    struct VerificationError: LocalizedError {
        let errorDescription: String?
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError(errorDescription: message) }
    }
    struct Catalog: Decodable {
        struct VPN: Decodable {
            let name: String
            let endpoint: String
            let address: String
            let openVPN: Bool
        }
        struct Connection: Decodable {
            let name: String
            let host: String
            let username: String
            let kind: String
            let folder: String
            let vpn: Int?
            let favorite: Bool
            let files: Bool?
        }
        struct SFTP: Decodable {
            struct Pane: Decodable {
                struct Entry: Decodable {
                    let name: String
                    let directory: Bool
                    let size: UInt64
                }
                let path: String
                let folders: [String: [Entry]]
                func files(at path: String) -> [TransferFile] {
                    (folders[path] ?? []).map {
                        TransferFile(name: $0.name, directory: $0.directory, regular: !$0.directory, size: $0.size)
                    }
                }
            }
            let local: Pane
            let remote: Pane
        }
        let sftp: SFTP
        let vpns: [VPN]
        let connections: [Connection]
    }
    static func openRequestedView(workspace: Workspace, connections: [SavedConnection]) {
        let argument = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--showcase-view=") }
        guard let view = argument?.components(separatedBy: "=").last else { return }
        if view == "vpn" {
            workspace.showWireGuard = true
            return
        }
        let selected = connections.first {
            switch view {
            case "files": return fileProfiles.contains($0.id)
            case "rdp": return $0.kind == .rdp
            case "vnc": return $0.kind == .vnc
            default: return $0.kind == .ssh && !fileProfiles.contains($0.id)
            }
        }
        if let selected { workspace.connect(ConnectionDraft(selected)) }
    }
    static func verify(_ container: ModelContainer) throws {
        let workspace = Workspace()
        workspace.modelContext = container.mainContext
        let connections = try container.mainContext.fetch(FetchDescriptor<SavedConnection>())
        let vpns = try container.mainContext.fetch(FetchDescriptor<SavedWireGuard>())
        let catalog = try loadCatalog()
        try require(
            connections.count == catalog.connections.count && vpns.count == catalog.vpns.count,
            "Seeded library does not match catalog connection/VPN counts.")
        for saved in connections {
            workspace.connect(ConnectionDraft(saved))
            guard let session = workspace.sessions.last else {
                throw VerificationError(errorDescription: "Demo connection did not create a session.")
            }
            try require(
                session.state == .connected && workspace.prompts.isEmpty,
                "Demo session did not connect without prompts.")
            if saved.kind == .ssh {
                let localPath = sftp.local.path
                let remotePath = sftp.remote.path
                let expectedLocal = sftp.local.files(at: localPath)
                let expectedRemote = sftp.remote.files(at: remotePath)
                try require(session.files.remotePath == remotePath, "Demo remote starting path is incorrect.")
                try require(session.files.remoteFiles == expectedRemote, "Demo remote listing differs from catalog.")
                try require(session.files.localURL?.path == localPath, "Demo local starting path is incorrect.")
                try require(session.files.localFiles == expectedLocal, "Demo local listing differs from catalog.")
                for path in sftp.remote.folders.keys.sorted() {
                    session.files.navigateRemote(path: path)
                    try require(session.files.remotePath == path, "Demo remote navigation failed.")
                    try require(
                        session.files.remoteFiles == sftp.remote.files(at: path),
                        "Demo remote folder differs from catalog.")
                    try require(
                        session.files.localFiles == expectedLocal, "Demo remote navigation changed local content.")
                }
                for path in sftp.local.folders.keys.sorted() {
                    session.files.localURL = URL(fileURLWithPath: path, isDirectory: true)
                    session.files.refreshLocal()
                    try require(
                        session.files.localFiles == sftp.local.files(at: path),
                        "Demo local folder differs from catalog.")
                }
            } else {
                try require(session.desktop?.mailbox.snapshot()?.1.width == 1440, "Demo desktop frame is missing.")
                try require(
                    session.observedDesktopSize == CGSize(width: 1440, height: 900),
                    "Demo desktop dimensions are incorrect.")
            }
            if saved.wireGuardID != nil {
                try require(session.vpnState == .connected, "Demo VPN status is not connected.")
            }
            workspace.reconnect(session)
            guard let reconnected = workspace.sessions.last else {
                throw VerificationError(errorDescription: "Demo reconnect did not create a session.")
            }
            try require(reconnected.state == .connected, "Demo reconnect failed.")
            reconnected.disconnect()
            try require(reconnected.state == .disconnected, "Demo disconnect failed.")
        }
        print(
            "PASS showcase: \(connections.count) catalog connections and \(vpns.count) VPN profiles; seeded sessions, file/desktop content, reconnect and disconnect"
        )
    }
    static var sftp: Catalog.SFTP!
    static var fileProfiles = Set<UUID>()
    static func loadCatalog() throws -> Catalog {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            throw VerificationError(errorDescription: "Demo catalog resource is missing.")
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        try require(!catalog.connections.isEmpty, "Demo catalog must contain at least one connection.")
        for connection in catalog.connections {
            try require(RemoteProtocol(rawValue: connection.kind) != nil, "Demo catalog has an unsupported protocol.")
            if let vpn = connection.vpn {
                try require(catalog.vpns.indices.contains(vpn), "Demo catalog has an invalid VPN index.")
            }
        }
        return catalog
    }
    static func seed(_ container: ModelContainer) throws {
        let catalog = try loadCatalog()
        sftp = catalog.sftp
        let context = container.mainContext
        var folders: [String: UUID] = [:]
        for connection in catalog.connections where folders[connection.folder] == nil {
            let folder = ConnectionFolder(name: connection.folder, order: folders.count)
            folders[connection.folder] = folder.id
            context.insert(folder)
        }
        var vpnIDs: [UUID] = []
        for vpn in catalog.vpns {
            var config = WireGuardConfiguration()
            config.openVPN = vpn.openVPN
            config.addresses = vpn.address
            config.dns = "10.24.0.1"
            config.endpoint = vpn.endpoint
            config.publicKey = Data(repeating: 42, count: 32).base64EncodedString()
            config.allowedIPs = "10.0.0.0/8"
            let saved = try SavedWireGuard(name: vpn.name, configuration: config)
            context.insert(saved)
            vpnIDs.append(saved.id)
            var credential = ConnectionCredential()
            credential.wireGuardPrivateKey = Data(repeating: 24, count: 32).base64EncodedString()
            credential.openVPNUsername = "barry"
            try CredentialStore.save(credential, for: saved.id)
        }
        for connection in catalog.connections {
            var draft = ConnectionDraft()
            draft.name = connection.name
            draft.host = connection.host
            draft.username = connection.username
            draft.kind = RemoteProtocol(rawValue: connection.kind)!
            draft.port = draft.kind == .ssh ? 22 : draft.kind == .rdp ? 3389 : 5900
            draft.folderID = folders[connection.folder]
            draft.favorite = connection.favorite
            draft.wireGuardID = connection.vpn.map { vpnIDs[$0] }
            draft.notes = connection.files == true ? "Research archives and shared project files" : ""
            context.insert(SavedConnection(draft: draft))
            if connection.files == true { fileProfiles.insert(draft.id) }
        }
        try context.save()
        UserDefaults.standard.set(true, forKey: "sftpDiskAccessExplained")
        UserDefaults.standard.set(false, forKey: "restoreWorkspace")
    }
}
