import Foundation
import SwiftData

@main struct SidebarMetadataChecks {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = Schema([SavedConnection.self, ConnectionFolder.self])
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [config])
        #if BEFORE_SIDEBAR
            let folder = ConnectionFolder(name: "Original folder", order: 7)
            var draft = ConnectionDraft()
            draft.name = "Original connection"
            draft.host = "fixture.example"
            draft.folderID = folder.id
            draft.favorite = true
            container.mainContext.insert(folder)
            container.mainContext.insert(SavedConnection(draft: draft))
            try container.mainContext.save()
        #else
            let folders = try container.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
            let profiles = try container.mainContext.fetch(FetchDescriptor<SavedConnection>())
            precondition(folders.count == 1 && profiles.count == 1)
            let folder = folders[0]
            let profile = profiles[0]
            precondition(folder.name == "Original folder" && folder.order == 7)
            precondition(profile.folderID == folder.id && profile.favorite)
            precondition(folder.parentID == nil && folder.isCollapsed == nil && profile.favoriteOrder == nil)
            let id = folder.id
            folder.name = "Renamed folder"
            folder.isCollapsed = true
            profile.favoriteOrder = 2
            try container.mainContext.save()
            let reopened = try ModelContainer(for: schema, configurations: [config])
            let restored = try reopened.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
            precondition(
                restored[0].id == id && restored[0].name == "Renamed folder" && restored[0].isCollapsed == true)
            print("PASS pre-sidebar library migration retains profiles and persistent folder identity")
        #endif
    }
}
