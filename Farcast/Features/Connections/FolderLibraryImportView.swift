import AppKit
import SwiftData
import SwiftUI

struct ExistingLibraryImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: Workspace
    @State private var source: FolderLibraryImport?
    @State private var sourceScope: URL?
    @State private var unlocked: ConnectionStorage?
    @State private var password = ""
    @State private var keyName = ""
    @State private var includeCredentials = true
    @State private var mode = FolderLibraryImportMode.merge
    @State private var message: String?
    @State private var review = false
    @State private var confirmClear = false
    @State private var historical = false
    @State private var result: FolderLibraryImport.Result?
    @State private var busy = false

    init(workspace: Workspace, source: FolderLibraryImport? = nil) {
        self.workspace = workspace
        _source = State(initialValue: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Connections").font(.title2.weight(.semibold))
            if let result {
                Label("Imported \(result.imported) connections", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text(
                    "\(result.vpnProfiles) VPN profiles imported · \(result.skipped) existing connections skipped · \(result.credentials) saved credentials imported"
                )
                Text("Your source folder and key were not changed. Keep them until you have checked your connections.")
                Text(
                    "No sessions were started. Server trust remains on this Mac; shared folders may need to be selected again."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(review ? "2. Review import" : "1. Choose a folder and unlock credentials").font(.headline)
                if let source {
                    path(source.root.path)
                    Text(
                        "\(source.profiles.count) connections · \(source.folders.count) folders · \(source.tunnels.count) VPN profiles"
                    )
                    if review { reviewFields(source) } else { unlockFields(source) }
                } else {
                    Text(
                        "Choose your .farcast-connections folder from another Mac or backup. Then choose the .farcast-key file that belongs to it."
                    )
                    Text(
                        "Quit any Farcast app using the source folder first. Hidden folders and key files are shown in both pickers."
                    )
                    .foregroundStyle(.secondary)
                }
                if let message { Text(message).foregroundStyle(.red).accessibilityLabel(message) }
                if busy { ProgressView("Importing connections and protecting credentials…") }
                HStack {
                    if review {
                        Button("Back") {
                            review = false
                            message = nil
                        }
                    } else {
                        Button("Choose Folder…") { chooseFolder() }
                        if source == nil {
                            Button("Previous App Library…") { historical = true }
                        }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    if review {
                        PrimaryActionButton(title: mode == .replace ? "Clear and Import…" : "Import") {
                            if mode == .replace { confirmClear = true } else { runImport() }
                        }.disabled(!workspace.sessions.isEmpty)
                    } else {
                        PrimaryActionButton(title: "Continue") {
                            review = true
                            message = nil
                        }
                        .disabled(
                            source == nil || (includeCredentials && unlocked == nil && source?.credentialCount != 0))
                    }
                }.disabled(busy)
                if !workspace.sessions.isEmpty {
                    Text("Close all session tabs before importing.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .textFieldStyle(.roundedBorder).buttonStyle(.bordered).controlSize(.regular)
        .padding(24).frame(width: 640)
        .interactiveDismissDisabled(busy)
        .sheet(isPresented: $historical) { HistoricalLibraryImportView(workspace: workspace) }
        .alert("Clear existing connections and credentials?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear and Import", role: .destructive) { runImport() }
        } message: {
            Text(
                "This replaces all saved connections, folders and VPN profiles, and removes their saved passwords and private keys from the current library. The source folder and key stay unchanged."
            )
        }
        .onAppear {
            if ConnectionStorageController.shared.settingsDraft?.dirty == true {
                message = "Apply or revert your pending Storage settings before importing."
            }
        }
        .onDisappear { releaseSource() }
    }

    private func path(_ value: String) -> some View {
        Text((value as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled).help(value).font(.callout)
    }

    @ViewBuilder private func unlockFields(_ source: FolderLibraryImport) -> some View {
        if source.credentialCount == 0 {
            Text("This library has no saved passwords or private keys.").foregroundStyle(.secondary)
        } else {
            Toggle("Include saved passwords and private keys", isOn: $includeCredentials)
            if includeCredentials {
                if source.manifest.protection == .keyFile {
                    Text("Choose the key file that belongs to this folder. It is used only for this import.")
                    HStack {
                        Button("Choose Key File…") { chooseKey() }
                        if !keyName.isEmpty { Text(keyName).lineLimit(1).truncationMode(.middle) }
                    }
                } else if source.manifest.protection == .password {
                    SecureField("Source library password", text: $password)
                    Button("Unlock") {
                        unlock(password: password)
                        password = ""
                    }
                    .disabled(password.isEmpty)
                }
                if unlocked != nil {
                    Label("Credentials ready to import", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Text("Connections will be imported without saved credentials. Enter them when connecting.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reviewFields(_ source: FolderLibraryImport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Import behavior", selection: $mode) {
                ForEach(FolderLibraryImportMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.radioGroup)
            Text(
                mode == .merge
                    ? "Adds new connections, folders and VPN profiles. Matching IDs and their existing credentials are kept unchanged; different IDs are added even when names match."
                    : "Removes all current connections, folders and VPN profiles and their saved credentials before adding this library. This cannot be undone after import."
            )
            .foregroundStyle(mode == .replace ? .orange : .secondary)
            Text(
                includeCredentials && source.credentialCount > 0
                    ? "Imported credentials use your current protection. \(CredentialStore.savingDescription)"
                    : "No passwords or private keys will be imported."
            )
            .font(.callout).foregroundStyle(.secondary)
            List(source.profiles) { profile in
                HStack {
                    Text(profile.name)
                    Spacer()
                    Text(profile.protocolName).foregroundStyle(.secondary)
                }
            }.frame(height: 180)
            Text("Settings, storage location and server trust are not imported.").font(.caption).foregroundStyle(
                .secondary)
        }
    }

    private func releaseSource() {
        source = nil
        unlocked = nil
        password = ""
        if let sourceScope { sourceScope.stopAccessingSecurityScopedResource() }
        sourceScope = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Farcast Connections Folder"
        panel.message = "Select the .farcast-connections folder itself. Hidden folders are visible."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = ConnectionStorage.realHome
        guard panel.runModal() == .OK, let url = panel.url else { return }
        releaseSource()
        keyName = ""
        message = nil
        includeCredentials = true
        if url.startAccessingSecurityScopedResource() { sourceScope = url }
        do {
            let currentRoot = context.container.configurations.first?.url.deletingLastPathComponent()
            source = try FolderLibraryImport(root: url, currentRoot: currentRoot)
            if source?.manifest.protection == .unencrypted { unlock() }
        } catch {
            releaseSource()
            message =
                (error as? FolderLibraryImportError)?.localizedDescription
                ?? FolderLibraryImportError.invalid.localizedDescription
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose Matching Farcast Key"
        panel.message = "Select the .farcast-key file saved with this library. Your current key will not change."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = source?.root.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        keyName = url.lastPathComponent
        unlock(key: url)
    }

    private func unlock(key: URL? = nil, password: String = "") {
        guard let source else { return }
        unlocked = nil
        do {
            unlocked = try ConnectionStorage.openForImport(source.root, keyFile: key, password: password)
            message = nil
        } catch {
            message =
                "This key or password cannot unlock the library. Try another, or turn off importing saved passwords and private keys."
        }
    }

    private func runImport() {
        guard let source, workspace.sessions.isEmpty else { return }
        guard ConnectionStorageController.shared.settingsDraft?.dirty != true else {
            message = "Apply or revert your pending Storage settings before importing."
            return
        }
        busy = true
        message = nil
        Task { @MainActor in
            await Task.yield()
            defer { busy = false }
            do {
                result = try source.apply(
                    to: context.container, mode: mode, unlocked: unlocked,
                    includeCredentials: includeCredentials && source.credentialCount > 0)
                releaseSource()
            } catch {
                message =
                    (error as? FolderLibraryImportError)?.localizedDescription
                    ?? "Import could not be completed. Check source credentials and current library access, then try again."
            }
        }
    }
}
