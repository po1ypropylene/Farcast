import Foundation

struct ConnectionDraft: Identifiable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var kind = RemoteProtocol.ssh
    var username = ""
    var domain = ""
    var authentication = SSHAuthentication.password
    var folderID: UUID?
    var favorite = false
    var notes = ""
    var fontSize = 14.0
    var terminalTheme = "Midnight"
    var desktopWidth = 1440
    var desktopHeight = 900
    var displayMode = RDPDisplayMode.fit
    var dynamicResolution = false
    var vncRemoteIsMac = false
    var effectiveDisplayMode: RDPDisplayMode {
        if (kind == .rdp || (kind == .vnc && vncRemoteIsMac)) && dynamicResolution { return .fit }
        if kind == .vnc && displayMode != .actualSize { return .fit }
        return displayMode
    }
    var launchFullScreen = false
    var useAllMonitors = false
    var retinaDisplay = false
    var clipboard = false
    var redirectedFolders: [RDPFolderExport] = []
    var redirectedFoldersUnavailable = false
    var wireGuardID: UUID?
    var audioPlayback = true
    var forwardingRules: [SSHForwardingRule] = []
    var forwardingRulesUnavailable = false
    init() {}
    init(_ saved: SavedConnection) {
        id = saved.id
        name = saved.name
        host = saved.host
        port = saved.port
        kind = saved.kind
        username = saved.username
        domain = saved.domain
        authentication = SSHAuthentication(rawValue: saved.authentication) ?? .password
        folderID = saved.folderID
        favorite = saved.favorite
        notes = saved.notes
        fontSize = saved.fontSize
        terminalTheme = saved.terminalTheme
        desktopWidth = saved.desktopWidth
        desktopHeight = saved.desktopHeight
        displayMode = RDPDisplayMode(rawValue: saved.rdpDisplayMode ?? "") ?? .fit
        dynamicResolution = saved.dynamicResolution
        vncRemoteIsMac = saved.vncRemoteIsMac ?? false
        launchFullScreen = saved.rdpLaunchFullScreen ?? false
        useAllMonitors = saved.rdpUseAllMonitors ?? false
        retinaDisplay = saved.rdpRetinaDisplay ?? false
        clipboard = saved.clipboard
        if let data = saved.rdpFolderExports {
            do { redirectedFolders = try JSONDecoder().decode([RDPFolderExport].self, from: data) } catch {
                redirectedFoldersUnavailable = true
            }
        }
        wireGuardID = saved.wireGuardID
        audioPlayback = saved.audioPlayback
        if let data = saved.sshForwardingRules {
            do {
                guard data.count <= 64 * 1024 else { throw CocoaError(.coderReadCorrupt) }
                forwardingRules = try JSONDecoder().decode([SSHForwardingRule].self, from: data)
            } catch {
                forwardingRulesUnavailable = true
            }
        }
    }
    var validationMessage: String? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHost.isEmpty { return "Enter a host name or IP address." }
        if cleanHost.contains("://") || cleanHost.contains(where: { $0.isWhitespace }) || cleanHost.contains("/") {
            return "Enter only the host name or IP address, without a URL or port."
        }
        if cleanHost.filter({ $0 == ":" }).count == 1 || cleanHost.contains("]:") {
            return "Enter the server address and port in their separate fields."
        }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        if (kind != .vnc || vncRemoteIsMac) && username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a username."
        }
        if kind == .vnc && vncRemoteIsMac {
            let limit = retinaDisplay ? (1920, 1080) : (3840, 2160)
            if !(200...limit.0).contains(desktopWidth) || !(200...limit.1).contains(desktopHeight) {
                return "Apple virtual-display dimensions must fit within \(limit.0) × \(limit.1)."
            }
        }
        if kind == .rdp && (!(200...8192).contains(desktopWidth) || !(200...8192).contains(desktopHeight)) {
            return "Desktop dimensions must be between 200 and 8192 pixels."
        }
        if kind == .rdp {
            if redirectedFoldersUnavailable {
                return "Saved folder settings could not be read. Reset them and choose the folders again."
            }
            if redirectedFolders.count > 16 { return "Redirect at most 16 local folders per connection." }
            var names = Set<String>()
            for folder in redirectedFolders {
                if let message = folder.validationMessage { return message }
                if !names.insert(folder.name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                    return "Give each redirected folder a different drive name."
                }
            }
        }
        if kind == .ssh {
            if forwardingRulesUnavailable {
                return "Saved tunnel settings could not be read. Reset them and add the rules again."
            }
            if forwardingRules.count > 16 { return "Add at most 16 tunnel rules per connection." }
            if Set(forwardingRules.map(\.id)).count != forwardingRules.count {
                return "Tunnel rule identities must be unique."
            }
            for rule in forwardingRules {
                if let message = rule.validationMessage { return message }
            }
        }
        return nil
    }
    mutating func normalize() {
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = host }
    }
    var endpointKey: String {
        "\(kind.rawValue)|\(host.lowercased())|\(port)" + (kind == .vnc && vncRemoteIsMac ? "|apple-rsa" : "")
    }
}
