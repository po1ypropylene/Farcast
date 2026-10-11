// Exact pre-display-settings entity identities, retained for automatic migration regression.
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
    var clipboard: Bool
    var rdpFolderExports: Data? = nil
    var wireGuardID: UUID? = nil
    var audioPlayback: Bool = true
    var lastConnected: Date?
    var created: Date
    init() {
        id = UUID(uuidString: "00000000-0000-4000-8000-000000000123")!
        name = "Synthetic pre-display profile"
        host = "fixture.invalid"
        port = 3389
        protocolName = "RDP"
        username = "fixture"
        domain = ""
        authentication = "password"
        folderID = nil
        favorite = true
        notes = "Preserve existing metadata"
        fontSize = 17
        terminalTheme = "Paper"
        desktopWidth = 1234
        desktopHeight = 777
        rdpDisplayMode = "actualSize"
        dynamicResolution = false
        clipboard = true
        rdpFolderExports = nil
        wireGuardID = nil
        audioPlayback = false
        lastConnected = Date(timeIntervalSince1970: 12345)
        created = Date(timeIntervalSince1970: 123)
    }
}

@main struct LegacyDisplayStore {
    @MainActor static func main() throws {
        let schema = Schema([SavedConnection.self])
        let configuration = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let container = try ModelContainer(for: schema, configurations: configuration)
        container.mainContext.insert(SavedConnection())
        try container.mainContext.save()
    }
}
