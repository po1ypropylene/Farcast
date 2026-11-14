import AppKit
import SwiftUI

struct ConnectionStorageSettings: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var controller: ConnectionStorageController
    @StateObject private var draft: ConnectionStorageDraft
    @State private var review = false
    @State private var generate = false
    @State private var keyName = ".farcast-key"
    @State private var generateAfterDismiss = false
    init(controller: ConnectionStorageController? = nil, draft: ConnectionStorageDraft? = nil) {
        let controller = controller ?? .shared
        self.controller = controller
        _draft = StateObject(wrappedValue: draft ?? ConnectionStorageDraft(controller: controller))
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView { fields.padding(20) }
            Divider()
            footer.padding(16).background(.background)
        }.textFieldStyle(.roundedBorder).controlSize(.regular)
            .onChange(of: draft.folderMode) { _, _ in draft.inspectDestination() }
            .sheet(isPresented: $review) { StorageSwitchReview(draft: draft) { review = false } }
            .sheet(
                isPresented: $generate,
                onDismiss: {
                    if generateAfterDismiss {
                        generateAfterDismiss = false
                        draft.chooseKey(generate: true, filename: keyName)
                    }
                },
                content: {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Generate New Key").font(.headline)
                        Text(
                            "Choose a filename, then a folder for the new AES-128 key. Existing files are never overwritten."
                        )
                        TextField("Key filename", text: $keyName)
                        if draft.sameFolder {
                            Text(
                                "Your current credentials stay readable. They will be re-encrypted only after you review and apply the protection change."
                            )
                        }
                        HStack {
                            Spacer()
                            Button("Cancel") { generate = false }.keyboardShortcut(.cancelAction)
                            Button("Choose Folder and Generate…") {
                                generateAfterDismiss = true
                                generate = false
                            }
                            .disabled(keyName.isEmpty || keyName.contains("/") || [".", ".."].contains(keyName))
                        }
                    }.textFieldStyle(.roundedBorder).padding(20).frame(width: 480)
                }
            )
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormSection(title: "Currently Using") {
                Label(
                    controller.container == nil ? "Library not open" : draft.activeTitle,
                    systemImage: controller.container == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(controller.container == nil ? .orange : .green)
                if let active = controller.storage {
                    Text(active.root.path).textSelection(.enabled).font(.caption)
                    Text("Credential protection: \(active.manifest.protection.title)")
                } else if controller.container != nil {
                    Text("Credential protection: macOS Keychain, with a local fallback")
                    if controller.hasLocalFallbackCredentials {
                        Label("Unencrypted local fallback files are in use", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(
                        "If Keychain is unavailable, Farcast saves credentials in files only your Mac account can read. These files are not encrypted."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(
                        "Open or unlock your library in the workspace, or choose another library below. No data has been reset."
                    )
                }
            }
            FormSection(title: "Import") {
                Text(
                    "Copy connections and saved passwords and private keys from a Farcast folder or backup into this library."
                )
                Button("Import Connections…") {
                    controller.workspace?.showLibraryImport = true
                    openWindow(id: "workspace")
                }
                .disabled(
                    draft.dirty || !controller.canChangeStorage || controller.container == nil
                        || controller.workspace == nil
                )
                .help("Apply or revert storage changes and close session tabs and editors before importing.")
            }
            FormSection(title: "Location") {
                Picker("Keep connections", selection: $draft.folderMode) {
                    Text("In Farcast’s app library").tag(false)
                    Text("In a folder I choose").tag(true)
                }.pickerStyle(.radioGroup)
                if draft.folderMode {
                    Text(
                        "Keep connections in a location you can back up. Use one Farcast instance at a time; preferences and server trust stay on this Mac."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    pathRow("Folder", url: draft.root)
                    HStack {
                        Button("Choose Folder…") { draft.chooseFolder(defaultFolder: false) }
                        Button("Use Default Folder…") { draft.chooseFolder(defaultFolder: true) }
                    }
                    Text("The default ~/.farcast-connections folder is hidden in Finder.").font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connections stay in Farcast’s private app data folder.").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
            FormSection(title: "Credential Protection") {
                if draft.folderMode {
                    Picker("Protect passwords and keys", selection: $draft.protection) {
                        ForEach(CredentialProtection.allCases) { Text($0.title).tag($0) }
                    }.disabled(draft.existingDestination)
                    if draft.existingDestination {
                        Text(
                            "This library uses its saved protection. Use Existing Data to open it before changing protection."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.protection == .keyFile { keyControls }
                    if draft.protection == .password {
                        SecureField(
                            draft.existingDestination ? "Library password" : "New library password",
                            text: $draft.password)
                        if draft.needsNewPassword { SecureField("Confirm new password", text: $draft.confirmation) }
                        notice(
                            "Keep your library password safe",
                            detail: "If you lose it, saved passwords and private keys cannot be recovered.",
                            warning: true)
                    }
                    if draft.protection == .unencrypted {
                        notice(
                            "Credentials will not be encrypted",
                            detail: "Anyone with access to the folder can read passwords and private keys.",
                            warning: true)
                    } else {
                        Text(
                            "Passwords and private keys are encrypted with AES-128-GCM. Hostnames, usernames and connection names are stored as plain text."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    LabeledContent("Protection", value: "macOS Keychain with local fallback")
                    Text("To choose key-file, password or unencrypted protection, select a custom folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.dirty {
                Label("Changes not applied", systemImage: "pencil.circle").foregroundStyle(.orange)
                if let issue = draft.configurationIssue { Label(issue, systemImage: "info.circle").font(.caption) }
            }
            if !draft.message.isEmpty {
                Text(draft.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Revert") { draft.revert() }.disabled(!draft.dirty)
                PrimaryActionButton(title: draft.actionTitle) {
                    draft.message = ""
                    draft.inspectDestination()
                    review = true
                }
                .disabled(!draft.dirty)
            }
        }
    }
    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            pathRow("Key file", url: draft.keyFile)
            Label(
                draft.keyReady ? "Key file found" : "Key file missing or access needed",
                systemImage: draft.keyReady ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(draft.keyReady ? Color.secondary : Color.orange)
            HStack {
                Menu("Change Key…") {
                    Button("Use Existing Key…") { draft.chooseKey(generate: false) }
                    if !draft.existingDestination { Button("Generate New Key…") { generate = true } }
                }
                Button("Back Up Key…") { backupKey() }.disabled(!draft.keyReady)
            }
            if draft.sameFolder {
                Text(
                    "Selecting a different key is a pending change. Applying it re-encrypts your saved credentials. Keep the old key for older backups and migration sources."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            notice(
                "Back up your key file",
                detail:
                    "If you lose it, saved passwords and private keys cannot be recovered. Keep the backup separate from this library.",
                warning: true)
            if draft.keyInsideFolder {
                notice(
                    "The key is inside the connection folder",
                    detail: "Anyone with both files can decrypt the credentials. Choose a key outside this folder.",
                    warning: true)
            }
        }
    }
    private func pathRow(_ label: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).fontWeight(.medium)
            HStack(alignment: .top) {
                Text(url.path).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .help("Reveal \(label.lowercased()) in Finder").accessibilityLabel(
                        "Reveal \(label.lowercased()) in Finder"
                    )
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
    private func notice(_ title: String, detail: String, warning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: warning ? "exclamationmark.triangle" : "info.circle").fontWeight(.medium)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    private func backupKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message =
            "Choose a separate backup folder. The new file will be named farcast-key-backup; existing files are never overwritten."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let data = try StorageFile.read(draft.keyFile, limit: 16)
            guard data.count == 16 else { throw ConnectionStorageError.invalid }
            try StorageFile.write(data, to: folder.appendingPathComponent("farcast-key-backup"), replace: false)
            draft.message = "Key backup created as farcast-key-backup. Keep it separate from your connection folder."
        } catch {
            draft.message =
                "The backup was not created. Choose an accessible folder without an existing farcast-key-backup file."
        }
    }
}

private struct StorageSwitchReview: View {
    @ObservedObject var draft: ConnectionStorageDraft
    let dismiss: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.switching ? "Switch Connection Storage" : "Change Credential Protection").font(.title2)
                LabeledContent("From", value: draft.controller.storage?.root.path ?? "Farcast app library")
                LabeledContent("To", value: draft.destinationTitle)
                Text(
                    draft.folderMode
                        ? "Credential protection: \(draft.protection.title)"
                        : "Credential protection: macOS Keychain with local fallback")
                if draft.switching {
                    Text(
                        "Migrate copies \(draft.sourceSummary). Your original data stays in place. Keychain may ask for approval; saved credentials are checked during migration."
                    )
                    if !draft.folderMode {
                        Text("Migration requires an empty app library. Switch Without Migrating opens it as it stands.")
                            .font(.caption)
                    }
                    if draft.existingDestination {
                        Label(
                            "Existing Farcast library. Use Existing Data to open it without copying or replacing anything.",
                            systemImage: "externaldrive")
                    } else if draft.folderMode && draft.destinationEmpty {
                        Label("Destination folder is empty", systemImage: "checkmark.circle")
                    }
                } else {
                    Text(
                        "All saved credentials will be re-encrypted with the selected protection. The active store changes only after every credential is ready. Keep the old key for older backups."
                    )
                }
                if let issue = draft.configurationIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if draft.controller.container == nil {
                    Label(
                        "Open the current library before migrating. You can still switch without migrating.",
                        systemImage: "info.circle")
                }
                if !draft.controller.canChangeStorage {
                    Label(
                        "Close session tabs and connection/import editors before continuing.",
                        systemImage: "exclamationmark.triangle"
                    ).foregroundStyle(.orange)
                    if let workspace = draft.controller.workspace, !workspace.sessions.isEmpty {
                        Button("Close Tabs") { for session in workspace.sessions { workspace.close(session) } }
                            .disabled(workspace.sessions.contains { $0.interruptionReason != nil })
                        if workspace.sessions.contains(where: { $0.interruptionReason != nil }) {
                            Text("Finish file transfers and tunnels, or close those tabs in the workspace first.").font(
                                .caption)
                        }
                    }
                }
                if !draft.message.isEmpty { Text(draft.message).foregroundStyle(.red) }
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if draft.switching {
                        Button(draft.existingDestination ? "Use Existing Data" : "Switch Without Migrating") {
                            apply(false)
                        }
                        .disabled(draft.configurationIssue != nil || !draft.controller.canChangeStorage)
                        PrimaryActionButton(title: "Migrate and Switch") { apply(true) }
                            .disabled(!draft.canMigrate || !draft.controller.canChangeStorage)
                    } else {
                        PrimaryActionButton(
                            title: draft.protection == .unencrypted
                                ? "Save Without Encryption" : "Re-encrypt Credentials"
                        ) { apply(false) }
                        .disabled(draft.configurationIssue != nil || !draft.controller.canChangeStorage)
                    }
                }
            }.fixedSize(horizontal: false, vertical: true).padding(24).frame(width: 600)
                .onChange(of: timeline.date) { _, _ in draft.inspectDestination() }
        }
    }
    private func apply(_ migrate: Bool) { if draft.apply(migrate: migrate) { dismiss() } }
}
