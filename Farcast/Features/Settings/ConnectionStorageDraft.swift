import AppKit
import Combine
import SwiftData

/// Pending settings are independent of the active store; inspection never unlocks or exports Keychain items.
@MainActor final class ConnectionStorageDraft: ObservableObject {
    let controller: ConnectionStorageController
    @Published var folderMode = false
    @Published var root = ConnectionStorage.defaultRoot
    @Published var protection = CredentialProtection.keyFile
    @Published var keyFile = ConnectionStorage.defaultKey
    @Published var password = ""
    @Published var confirmation = ""
    @Published var message = ""
    var scope: URL?
    var keyAuthorized = false
    @Published var keySelectionChanged = false
    private var inspectedRoot: String?
    private(set) var destinationManifest: ConnectionStorageManifest?
    private(set) var destinationIssue: String?
    private(set) var destinationEmpty = true

    init(controller: ConnectionStorageController) {
        self.controller = controller
        revert()
    }
    var sameFolder: Bool {
        folderMode && controller.storage?.root.standardizedFileURL.path == root.standardizedFileURL.path
    }
    var switching: Bool { folderMode != (controller.storage != nil) || (folderMode && !sameFolder) }
    var existingDestination: Bool { switching && folderMode && destinationManifest != nil }
    var dirty: Bool {
        if switching { return true }
        guard folderMode, let active = controller.storage else { return false }
        return protection != active.manifest.protection
            || (protection == .keyFile && (keySelectionChanged || keyFile.path != active.manifest.keyFile))
            || (protection == .password && (!password.isEmpty || !confirmation.isEmpty))
    }
    var activeTitle: String { controller.storage == nil ? "Farcast app library" : "Custom folder" }
    var destinationTitle: String { folderMode ? root.path : "Farcast app library" }
    var actionTitle: String { (switching || !folderMode) ? "Switch Storage…" : "Change Protection…" }
    var needsNewPassword: Bool { folderMode && protection == .password && !existingDestination }
    var keyReady: Bool {
        guard let values = try? keyFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 16
        else { return false }
        return FileManager.default.isReadableFile(atPath: keyFile.path)
    }
    var keyInsideFolder: Bool {
        keyFile.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }
    var configurationIssue: String? {
        if folderMode {
            if let destinationIssue { return destinationIssue }
            if switching && scope == nil { return "Choose the folder to authorize access before switching." }
            if protection == .keyFile {
                if !keyReady { return "The key file is missing, inaccessible, or is not a 16-byte AES key." }
                if !keyAuthorized && controller.storage?.manifest.keyFile != keyFile.path {
                    return "Select the existing key file or generate a new key to authorize access."
                }
            }
            if protection == .password {
                if password.isEmpty {
                    return existingDestination ? "Enter this library’s password." : "Enter a new library password."
                }
                if needsNewPassword && password != confirmation { return "The passwords do not match." }
            }
        }
        return nil
    }
    var canMigrate: Bool {
        configurationIssue == nil && controller.container != nil && (!folderMode || destinationEmpty)
    }
    var sourceSummary: String {
        guard let context = controller.container?.mainContext,
            let connections = try? context.fetchCount(FetchDescriptor<SavedConnection>()),
            let vpns = try? context.fetchCount(FetchDescriptor<SavedWireGuard>())
        else { return "Saved connections, folders and VPN profiles" }
        return "\(connections) saved connections and \(vpns) VPN profiles, their folders and saved credentials"
    }
    func revert() {
        folderMode = controller.storage != nil
        root = controller.storage?.root ?? ConnectionStorage.defaultRoot
        protection = controller.storage?.manifest.protection ?? .keyFile
        keyFile = controller.storage?.manifest.keyFile.map { URL(fileURLWithPath: $0) } ?? ConnectionStorage.defaultKey
        password = ""
        confirmation = ""
        scope = nil
        keyAuthorized = false
        keySelectionChanged = false
        message = ""
        inspectedRoot = nil
        inspectDestination()
    }
    func inspectDestination() {
        destinationIssue = nil
        destinationManifest = nil
        destinationEmpty = true
        guard folderMode, !sameFolder else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ConnectionStorageError.invalid
            }
            guard fm.isWritableFile(atPath: root.path) else {
                destinationIssue = "The destination is read-only. Choose a writable folder."
                return
            }
            let names = try fm.contentsOfDirectory(atPath: root.path)
            destinationEmpty = names.isEmpty
            if names.contains("storage.json") {
                let manifest = try ConnectionStorage.manifest(at: root)
                destinationManifest = manifest
                if inspectedRoot != root.path {
                    protection = manifest.protection
                    keyFile = manifest.keyFile.map { URL(fileURLWithPath: $0) } ?? ConnectionStorage.defaultKey
                    keyAuthorized = controller.storage?.manifest.keyFile == keyFile.path
                    password = ""
                    confirmation = ""
                }
            } else if !names.isEmpty {
                destinationIssue =
                    "This folder contains other files. Choose an empty folder or an existing Farcast library."
            }
        } catch { destinationIssue = "The destination cannot be inspected. Choose the folder again to restore access." }
        inspectedRoot = root.path
    }
    func chooseFolder(defaultFolder: Bool) {
        do {
            if let (url, selectedScope) = try ConnectionStorageAccess.chooseRoot(useDefault: defaultFolder) {
                root = url
                scope = selectedScope
                inspectedRoot = nil
                inspectDestination()
                message = ""
            }
        } catch { message = "The folder could not be authorized. Your active library is unchanged." }
    }
    func chooseKey(generate: Bool, filename: String = ".farcast-key") {
        do {
            if let selected = try ConnectionStorageAccess.chooseKey(generate: generate, filename: filename) {
                if existingDestination, let originalPath = destinationManifest?.keyFile,
                    selected.resolvingSymlinksInPath().path
                        != URL(fileURLWithPath: originalPath).resolvingSymlinksInPath().path
                {
                    message =
                        "Select this library’s original key at the displayed path. Switch to the library before changing its protection."
                    return
                }
                keyFile = selected
                keyAuthorized = true
                keySelectionChanged = true
                message = ""
            }
        } catch {
            message =
                generate
                ? "The key was not generated. Use a new filename; existing files are never overwritten."
                : "Choose a regular file containing exactly 16 bytes."
        }
    }
    func apply(migrate: Bool) -> Bool {
        guard configurationIssue == nil else {
            message = configurationIssue ?? "Review the settings."
            return false
        }
        let wasSwitching = switching
        do {
            try controller.apply(
                folderMode: folderMode, root: root, scope: scope, protection: protection,
                keyFile: keyFile, password: password, migrate: migrate)
            revert()
            message =
                controller.storage?.supersededFilesRemain == true
                ? "Protection changed, but old credential files could not be removed. They may still be unencrypted."
                : migrate
                    ? "Migration complete. Your original library and credentials are still in place."
                    : wasSwitching
                        ? "Storage updated. Your previous library is still in place."
                        : "Credential protection updated. Older backups keep their original protection."
            return true
        } catch ConnectionStorageError.exists {
            message =
                "The destination is not empty or contains conflicting credentials. Use Existing Data or choose an empty folder. Your active library is unchanged."
        } catch {
            message =
                "The change could not be completed. Check access and the library password or original key. Your active library is unchanged."
        }
        return false
    }
}
