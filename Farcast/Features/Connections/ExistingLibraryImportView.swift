import AppKit
import SwiftData
import SwiftUI

struct ExistingLibraryImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    @State private var includeLocalCredentials = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import existing library").font(.title2.weight(.semibold))
            Text(
                "Quit the previous app, then select its container’s Data/Library folder. Import requires an empty Farcast library and no open session tabs."
            )
            Text(
                "Saved profiles, folders, WireGuard connections, settings, trust decisions and disconnected tab restoration are copied. The original data stays in place. No connections start automatically."
            )
            .foregroundStyle(.secondary)
            Toggle("Copy saved local credentials", isOn: $includeLocalCredentials)
            Text(
                "Local credentials include passwords, imported private keys and WireGuard keys. Their copies are owner-only files and are not encrypted. Keychain items are not copied; enter those credentials again. Choose local folders and SSH key files again if macOS requests access."
            )
            .font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red).accessibilityLabel(message) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                PrimaryActionButton(title: "Choose Library Folder…") { chooseLibrary() }
                    .disabled(!workspace.sessions.isEmpty)
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(24).frame(width: 620)
    }

    private func chooseLibrary() {
        guard
            !NSWorkspace.shared.runningApplications.contains(where: {
                $0.bundleIdentifier == PreviousLibraryIdentity.bundle
            })
        else {
            message = "Quit the previous app before importing its library."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose Existing Library Folder"
        panel.message = "Select Data/Library inside the previous app’s container. Quit that app before continuing."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let library = panel.url else { return }
        let scoped = library.startAccessingSecurityScopedResource()
        defer { if scoped { library.stopAccessingSecurityScopedResource() } }
        do {
            guard workspace.sessions.isEmpty else { throw ExistingLibraryImportError.nonemptyDestination }
            let count = try ExistingLibraryImporter.importLibrary(
                from: library, into: context.container, includeLocalCredentials: includeLocalCredentials)
            let saved = try context.fetch(FetchDescriptor<SavedConnection>())
            workspace.restoreWorkspace(saved)
            dismiss()
            workspace.error =
                "Imported \(count) saved connections. Enter any Keychain credentials and reselect shared folders before reconnecting."
        } catch {
            message =
                (error as? ExistingLibraryImportError)?.localizedDescription
                ?? ExistingLibraryImportError.invalidSource.localizedDescription
        }
    }
}
