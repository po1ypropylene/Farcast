import Foundation
import SwiftData

@main struct DisplayMigrationChecks {
    @MainActor static func main() throws {
        let schema = Schema([SavedConnection.self])
        let configuration = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let container = try ModelContainer(for: schema, configurations: configuration)
        let saved = try container.mainContext.fetch(FetchDescriptor<SavedConnection>()).first!
        precondition(saved.id == UUID(uuidString: "00000000-0000-4000-8000-000000000123"))
        precondition(saved.name == "Synthetic pre-display profile" && saved.host == "fixture.invalid")
        precondition(saved.favorite && saved.notes == "Preserve existing metadata" && saved.fontSize == 17)
        precondition(saved.desktopWidth == 1234 && saved.desktopHeight == 777 && saved.rdpDisplayMode == "actualSize")
        precondition(!saved.dynamicResolution && saved.clipboard && !saved.audioPlayback)
        precondition(
            saved.created == Date(timeIntervalSince1970: 123)
                && saved.lastConnected == Date(timeIntervalSince1970: 12345))
        precondition(
            saved.rdpLaunchFullScreen == nil && saved.rdpUseAllMonitors == nil && saved.rdpRetinaDisplay == nil)
        var draft = ConnectionDraft(saved)
        precondition(!draft.launchFullScreen && !draft.useAllMonitors && !draft.retinaDisplay)
        draft.launchFullScreen = true
        draft.useAllMonitors = true
        draft.retinaDisplay = true
        saved.update(from: draft)
        try container.mainContext.save()
        let reopened = try ModelContainer(for: schema, configurations: configuration)
        let roundTrip = ConnectionDraft(try reopened.mainContext.fetch(FetchDescriptor<SavedConnection>()).first!)
        precondition(
            roundTrip.id == draft.id && roundTrip.launchFullScreen && roundTrip.useAllMonitors
                && roundTrip.retinaDisplay)
        precondition(roundTrip.desktopWidth == 1234 && roundTrip.desktopHeight == 777)
        print("PASS automatic migration preserves pre-display profile IDs, metadata, dimensions and legacy defaults")
    }
}
