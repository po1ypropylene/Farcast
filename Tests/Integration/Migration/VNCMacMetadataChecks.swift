import Foundation
import SwiftData

@main struct VNCMacMetadataChecks {
    @MainActor static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let container = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(url: url))
        let context = container.mainContext
        #if BEFORE_MAC_VNC
            var draft = ConnectionDraft()
            draft.id = UUID(uuidString: "63109BB2-FF92-4B40-B4A7-599605001234")!
            draft.kind = .vnc
            draft.host = "migration.fixture.invalid"
            draft.port = 5900
            draft.username = "fixture"
            draft.notes = "Retained metadata"
            draft.displayMode = .actualSize
            context.insert(SavedConnection(draft: draft))
            try context.save()
        #else
            let all = try context.fetch(FetchDescriptor<SavedConnection>())
            precondition(all.count == 1)
            let saved = all[0]
            precondition(saved.id.uuidString == "63109BB2-FF92-4B40-B4A7-599605001234")
            precondition(saved.notes == "Retained metadata" && saved.username == "fixture")
            precondition(saved.kind == .vnc && saved.port == 5900)
            if CommandLine.arguments.count == 2 {
                precondition(!ConnectionDraft(saved).vncRemoteIsMac)
                var draft = ConnectionDraft(saved)
                draft.vncRemoteIsMac = true
                draft.dynamicResolution = true
                saved.update(from: draft)
                try context.save()
            } else {
                precondition(ConnectionDraft(saved).vncRemoteIsMac && saved.dynamicResolution)
            }
        #endif
        print("PASS Mac VNC metadata migration and retained profile identity")
    }
}
