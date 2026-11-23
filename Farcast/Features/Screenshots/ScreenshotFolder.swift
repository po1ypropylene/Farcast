import AppKit

struct ScreenshotFolder: Sendable {
    static let bookmarkKey = "screenshot.folderBookmark"
    static let pathKey = "screenshot.folderPath"
    static var desktop: URL { ConnectionStorage.realHome.appendingPathComponent("Desktop", isDirectory: true) }

    let bookmark: Data?
    let url: URL

    init(defaults: UserDefaults = .standard) {
        bookmark = defaults.data(forKey: Self.bookmarkKey)
        url = defaults.string(forKey: Self.pathKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.desktop
    }

    enum Issue: LocalizedError {
        case access, missing

        var errorDescription: String? {
            switch self {
            case .access:
                return String(localized: "Farcast can’t write to this folder. Choose it again to grant access.")
            case .missing: return String(localized: "Folder not found. Choose a folder.")
            }
        }
    }

    func withAccess<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let bookmark else { throw Issue.access }
        var stale = false
        guard
            let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), !stale, resolved.startAccessingSecurityScopedResource()
        else { throw Issue.access }
        defer { resolved.stopAccessingSecurityScopedResource() }
        return try operation(resolved)
    }

    func check() throws {
        try withAccess { resolved in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue
            else { throw Issue.missing }
            guard FileManager.default.isWritableFile(atPath: resolved.path) else { throw Issue.access }
        }
    }

    @MainActor @discardableResult
    static func choose(at initial: URL?, requireDesktop: Bool = false) throws -> Bool {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Screenshots Folder")
        panel.prompt = String(localized: "Allow")
        panel.directoryURL = initial
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        ScreenshotService.elevateModal(panel)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if requireDesktop && url.standardizedFileURL.path != desktop.standardizedFileURL.path { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(url.path, forKey: pathKey)
        return true
    }

    @MainActor func reveal() {
        _ = try? withAccess { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0.path) }
    }
}
