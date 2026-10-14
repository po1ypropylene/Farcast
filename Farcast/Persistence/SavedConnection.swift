import Foundation
import SwiftData

@Model final class SavedConnection {
    @Attribute(.unique) var id: UUID
    var name: String
    var host: String
    var port: Int
    var protocolName: String
    var username: String
    var domain: String
    var authentication: String
    var folderID: UUID?
    var favorite: Bool
    var notes: String
    var fontSize: Double
    var terminalTheme: String
    var desktopWidth: Int
    var desktopHeight: Int
    var rdpDisplayMode: String? = nil
    var dynamicResolution: Bool
    var rdpLaunchFullScreen: Bool? = nil
    var rdpUseAllMonitors: Bool? = nil
    var rdpRetinaDisplay: Bool? = nil
    var clipboard: Bool
    var rdpFolderExports: Data? = nil
    var wireGuardID: UUID? = nil
    var audioPlayback: Bool = true
    var sshForwardingRules: Data? = nil
    var lastConnected: Date?
    var created: Date
    init(draft: ConnectionDraft) {
        id = draft.id
        name = draft.name
        host = draft.host
        port = draft.port
        protocolName = draft.kind.rawValue
        username = draft.username
        domain = draft.domain
        authentication = draft.authentication.rawValue
        folderID = draft.folderID
        favorite = draft.favorite
        notes = draft.notes
        fontSize = draft.fontSize
        terminalTheme = draft.terminalTheme
        desktopWidth = draft.desktopWidth
        desktopHeight = draft.desktopHeight
        rdpDisplayMode = draft.displayMode.rawValue
        dynamicResolution = draft.dynamicResolution
        rdpLaunchFullScreen = draft.launchFullScreen
        rdpUseAllMonitors = draft.useAllMonitors
        rdpRetinaDisplay = draft.retinaDisplay
        clipboard = draft.clipboard
        rdpFolderExports = try? JSONEncoder().encode(draft.redirectedFolders)
        wireGuardID = draft.wireGuardID
        audioPlayback = draft.audioPlayback
        sshForwardingRules = try? JSONEncoder().encode(draft.forwardingRules)
        created = Date()
    }
    func duplicate() -> SavedConnection {
        var draft = ConnectionDraft(self)
        draft.id = UUID()
        draft.name += " Copy"
        let copy = SavedConnection(draft: draft)
        // Retain optional/raw metadata exactly, including settings from newer versions.
        copy.protocolName = protocolName
        copy.authentication = authentication
        copy.rdpDisplayMode = rdpDisplayMode
        copy.rdpLaunchFullScreen = rdpLaunchFullScreen
        copy.rdpUseAllMonitors = rdpUseAllMonitors
        copy.rdpRetinaDisplay = rdpRetinaDisplay
        copy.rdpFolderExports = rdpFolderExports
        copy.sshForwardingRules = sshForwardingRules
        return copy
    }
    var kind: RemoteProtocol { RemoteProtocol(rawValue: protocolName) ?? .ssh }
    func update(from draft: ConnectionDraft) {
        name = draft.name
        host = draft.host
        port = draft.port
        protocolName = draft.kind.rawValue
        username = draft.username
        domain = draft.domain
        authentication = draft.authentication.rawValue
        folderID = draft.folderID
        favorite = draft.favorite
        notes = draft.notes
        fontSize = draft.fontSize
        terminalTheme = draft.terminalTheme
        desktopWidth = draft.desktopWidth
        desktopHeight = draft.desktopHeight
        rdpDisplayMode = draft.displayMode.rawValue
        dynamicResolution = draft.dynamicResolution
        rdpLaunchFullScreen = draft.launchFullScreen
        rdpUseAllMonitors = draft.useAllMonitors
        rdpRetinaDisplay = draft.retinaDisplay
        clipboard = draft.clipboard
        rdpFolderExports = try? JSONEncoder().encode(draft.redirectedFolders)
        wireGuardID = draft.wireGuardID
        audioPlayback = draft.audioPlayback
        sshForwardingRules = try? JSONEncoder().encode(draft.forwardingRules)
    }
}
