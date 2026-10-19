import AppKit
import SwiftData

@MainActor enum ShowcaseLibrary {
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
        precondition(connections.count >= 6 && vpns.count >= 3)
        for saved in connections {
            workspace.connect(ConnectionDraft(saved))
            let session = workspace.sessions.last!
            precondition(session.state == .connected && workspace.prompts.isEmpty)
            if saved.kind == .ssh {
                precondition(session.files.remoteFiles.count == 9)
                session.files.navigateRemote(path: "/home/research/Reports")
                precondition(session.files.remotePath == "/home/research/Reports")
                precondition(session.files.localFiles.count == 9)
            } else {
                precondition(session.desktop?.mailbox.snapshot()?.1.width == 1440)
                precondition(session.observedDesktopSize == CGSize(width: 1440, height: 900))
            }
            if saved.wireGuardID != nil { precondition(session.vpnState == .connected) }
            workspace.reconnect(session)
            precondition(workspace.sessions.last!.state == .connected)
            workspace.sessions.last!.disconnect()
            precondition(workspace.sessions.last!.state == .disconnected)
        }
        print("PASS showcase: seeded library, SSH, SFTP browsing, RDP/VNC frames, VPN status, reconnect and disconnect")
    }
    static var fileProfiles = Set<UUID>()
    static func seed(_ container: ModelContainer) throws {
        let url = Bundle.main.url(forResource: "catalog", withExtension: "json")!
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
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
            credential.openVPNUsername = "barry.allen"
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
