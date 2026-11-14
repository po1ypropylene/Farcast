import AppKit
import ApplicationServices
import SwiftData
import SwiftUI

/// Uses an isolated preference suite and disposable folders; never opens the user's library or Keychain.
@MainActor enum ConnectionStorageChecks {
    static func run() async throws {
        func waitForLayout() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Farcast-storage-checks-\(UUID())")
        try StorageFile.directory(root)
        defer {
            try? manager.removeItem(at: root)
            ConnectionStorageSession.use(nil)
        }
        // Optional native picker review: select this owned directory twice to verify overwrite refusal.
        if ProcessInfo.processInfo.environment["FARCAST_STORAGE_KEY_PICKER_REVIEW"] == "1" {
            print("REVIEW key-generation destination: \(root.path)")
            fflush(stdout)
            guard let generated = try ConnectionStorageAccess.chooseKey(generate: true) else {
                throw ConnectionStorageError.invalid
            }
            precondition(generated.lastPathComponent == ".farcast-key")
            precondition(
                generated.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == root.resolvingSymlinksInPath().path)
            let originalKey = try StorageFile.read(generated)
            precondition(originalKey.count == 16)
            do {
                _ = try ConnectionStorageAccess.chooseKey(generate: true)
                preconditionFailure("Key generation must refuse an existing key")
            } catch ConnectionStorageError.exists {}
            let retainedKey = try StorageFile.read(generated)
            precondition(originalKey == retainedKey)
            print("PASS native key generation creates AES-128 key and refuses to overwrite an existing file")
        }
        let suite = "com.peterpo.farcast.storage-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = try ConnectionStorage.create(
            root.appendingPathComponent("source"), keyFile: root.appendingPathComponent("source-key"))
        let container = try ConnectionStorageController.folderContainer(source.root)
        let controller = ConnectionStorageController(defaults: defaults, container: container, storage: source)
        ConnectionStorageSession.use(source)
        var draft = ConnectionDraft()
        draft.name = "Synthetic connection"
        draft.host = "fixture.invalid"
        let connection = SavedConnection(draft: draft)
        container.mainContext.insert(connection)
        try container.mainContext.save()
        try source.credentials.save(ConnectionCredential(password: "synthetic-password"), for: connection.id)
        let destination = root.appendingPathComponent("destination")
        try controller.apply(
            folderMode: true, root: destination, scope: nil, protection: .password,
            keyFile: root.appendingPathComponent("unused"), password: "synthetic-unlock", migrate: true)
        precondition(controller.storage?.root == destination)
        let sourcePassword = try source.credentials.load(connection.id)?.password
        precondition(sourcePassword == "synthetic-password")
        let migratedPassword = try CredentialStore.load(connection.id)?.password
        precondition(migratedPassword == "synthetic-password")
        let migratedID = try controller.container!.mainContext.fetch(FetchDescriptor<SavedConnection>()).first?.id
        precondition(migratedID == connection.id)
        let previousBookmark = defaults.data(forKey: "connectionStorageBookmark")
        do {
            try controller.apply(
                folderMode: true, root: source.root, scope: nil, protection: .keyFile,
                keyFile: root.appendingPathComponent("source-key"), password: "", migrate: true)
            preconditionFailure("Migration must refuse a nonempty library")
        } catch ConnectionStorageError.exists {}
        precondition(defaults.data(forKey: "connectionStorageBookmark") == previousBookmark)
        precondition(controller.storage?.root == destination)
        let empty = root.appendingPathComponent("empty")
        try controller.apply(
            folderMode: true, root: empty, scope: nil, protection: .unencrypted,
            keyFile: root.appendingPathComponent("unused"), password: "", migrate: false)
        let emptyCount = try controller.container!.mainContext.fetchCount(FetchDescriptor<SavedConnection>())
        precondition(emptyCount == 0)
        let emptyCredential = try CredentialStore.load(connection.id)
        precondition(emptyCredential == nil)
        let workspace = Workspace(defaults: defaults)
        controller.workspace = workspace
        workspace.sessions = [RemoteSession(profile: draft, workspace: workspace, persistent: false)]
        do {
            try controller.apply(
                folderMode: true, root: destination, scope: nil, protection: .password,
                keyFile: root.appendingPathComponent("unused"), password: "synthetic-unlock", migrate: false)
            preconditionFailure("Storage must not switch with session tabs")
        } catch ConnectionStorageError.locked {}
        controller.workspace = nil
        try controller.apply(
            folderMode: true, root: empty, scope: nil, protection: .keyFile,
            keyFile: root.appendingPathComponent("source-key"), password: "", migrate: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: AppSettings(storageController: controller).preferredColorScheme(scheme))
            window.makeKeyAndOrderFront(nil)
            waitForLayout()
            // Capture the complete storage form separately so every control can be inspected.
            let form = NSHostingView(
                rootView: ConnectionStorageSettings(controller: controller)
                    .frame(width: 580, height: 720).preferredColorScheme(scheme))
            window.contentView = form
            waitForLayout()
            window.setContentSize(form.fittingSize)
            waitForLayout()
            if CommandLine.arguments.count > 1, let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to:
                        URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("storage-\(scheme).png"))
            }
        }
        // Draft changes and revert must never alter the active library or its credential protection.
        let pending = ConnectionStorageDraft(controller: controller)
        precondition(!pending.dirty)
        pending.keySelectionChanged = true
        precondition(pending.dirty, "Explicit key selection must permit re-encryption even when the path is unchanged")
        pending.revert()
        precondition(!pending.dirty)
        pending.protection = .password
        pending.password = "synthetic-new-password"
        pending.confirmation = "different"
        precondition(pending.dirty && pending.configurationIssue != nil)
        pending.revert()
        precondition(!pending.dirty && pending.password.isEmpty && pending.confirmation.isEmpty)
        pending.folderMode = true
        pending.root = source.root
        pending.scope = root
        pending.inspectDestination()
        precondition(pending.existingDestination && !pending.canMigrate)
        pending.revert()
        precondition(controller.storage?.root == empty)
        // Inspect the actual migration review and cancellation with a pending destination.
        let legacyRoot = root.appendingPathComponent("legacy-credentials")
        try LocalCredentialStore(root: legacyRoot).save(ConnectionCredential(password: "synthetic"), for: UUID())
        let legacyPreview = ConnectionStorageController(
            defaults: defaults, container: container, legacyCredentialRoot: legacyRoot)
        precondition(legacyPreview.hasLocalFallbackCredentials)
        let reviewDraft = ConnectionStorageDraft(controller: legacyPreview)
        reviewDraft.folderMode = true
        reviewDraft.root = root.appendingPathComponent("review-destination")
        reviewDraft.scope = root
        reviewDraft.protection = .unencrypted
        reviewDraft.inspectDestination()
        precondition(reviewDraft.dirty && reviewDraft.canMigrate)
        let promptView = NSHostingView(
            rootView: ConnectionStorageSettings(controller: legacyPreview, draft: reviewDraft)
                .frame(width: 580, height: 720))
        window.contentView = promptView
        window.setContentSize(promptView.fittingSize)
        let accessibilityApp = AXUIElementCreateApplication(getpid())
        AXUIElementSetAttributeValue(accessibilityApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(accessibilityApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        func attribute(_ node: NSObject, _ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        func nodes() -> [NSObject] {
            var visited = Set<ObjectIdentifier>()
            func walk(_ node: NSObject) -> [NSObject] {
                guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                let children = (attribute(node, "accessibilityChildren") as? [NSObject]) ?? []
                let sheets = (node as? NSWindow)?.attachedSheet.map { [$0] } ?? []
                return [node] + (children + sheets).flatMap(walk)
            }
            return walk(window)
        }
        func press(_ title: String, role: String = "AXButton") {
            guard
                let button = nodes().first(where: {
                    attribute($0, "accessibilityLabel") as? String == title
                        && attribute($0, "accessibilityRole") as? String == role
                })
            else { preconditionFailure("Missing synthetic storage button") }
            if let native = button as? NSButton {
                native.performClick(nil)
            } else {
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                _ = unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector)
            }
            settle()
        }
        settle()
        press("Switch Storage…")
        let labels = nodes().compactMap { attribute($0, "accessibilityLabel") as? String }
        precondition(labels.contains("Migrate and Switch"))
        precondition(labels.contains("Switch Without Migrating"))
        press("Cancel")
        precondition(legacyPreview.storage == nil)
        precondition(reviewDraft.dirty)
        reviewDraft.revert()
        precondition(!reviewDraft.dirty)
        // Use the real import view with a synthetic encrypted source and isolated destination.
        let importSource = try FolderLibraryImport(root: source.root, currentRoot: controller.storage?.root)
        let importWorkspace = Workspace(defaults: defaults)
        window.contentView = NSHostingView(
            rootView: ExistingLibraryImportView(workspace: importWorkspace, source: importSource)
                .modelContainer(controller.container!))
        window.setContentSize(NSSize(width: 688, height: 540))
        settle()
        let importLabels = nodes().compactMap { attribute($0, "accessibilityLabel") as? String }
        precondition(importLabels.contains("Choose Key File…"))
        let next = nodes().first { attribute($0, "accessibilityLabel") as? String == "Continue" }
        precondition(next != nil && attribute(next!, "isAccessibilityEnabled") as? Bool != true)
        press("Include saved passwords and private keys", role: "AXCheckBox")
        press("Continue")
        if let view = window.contentView { window.setContentSize(view.fittingSize) }
        settle()
        let reviewLabels = nodes().compactMap { attribute($0, "accessibilityLabel") as? String }
        precondition(reviewLabels.contains("Merge with existing connections"))
        precondition(reviewLabels.contains("Clear existing and import"))
        if CommandLine.arguments.count > 1, let view = window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to:
                    URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("import-review.png"))
        }
        press("Import")
        try await Task.sleep(for: .milliseconds(200))
        settle()
        let imported = try ModelContext(controller.container!).fetch(FetchDescriptor<SavedConnection>())
        let doneLabels = nodes().compactMap { attribute($0, "accessibilityLabel") as? String }
        precondition(
            imported.count == 1 && imported.first?.id == connection.id,
            "Synthetic import count: \(imported.count); labels: \(doneLabels)")
        precondition(doneLabels.contains("Done"))
        print("PASS import unlock gating, metadata-only choice, merge/clear review and completed isolated UI import")
        print(
            "PASS pending storage edits, Revert, existing-library preflight, fallback disclosure and migration review cancellation"
        )
        print(
            "PASS isolated storage switching, explicit migration, source retention, conflict rollback, no-migration and active-tab refusal"
        )
    }
}
