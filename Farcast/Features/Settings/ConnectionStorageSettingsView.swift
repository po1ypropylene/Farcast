import AppKit
import CryptoKit
import SwiftData
import SwiftUI

struct ConnectionStorageSettings: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: ConnectionStorageController
    @StateObject private var draft: ConnectionStorageDraft
    @State private var generate = false
    @State private var keyName = ".farcast-key"
    @State private var generateAfterDismiss = false
    @State private var backupRevision = 0
    var reportHeight: (CGFloat) -> Void
    init(
        controller: ConnectionStorageController? = nil, draft: ConnectionStorageDraft? = nil,
        reportHeight: @escaping (CGFloat) -> Void = { _ in }
    ) {
        let controller = controller ?? .shared
        self.controller = controller
        self.reportHeight = reportHeight
        _draft = StateObject(wrappedValue: draft ?? ConnectionStorageDraft(controller: controller))
    }
    var body: some View {
        SettingsPane(reportHeight: reportHeight) {
            fields
        } footer: {
            if draft.dirty {
                Divider()
                footer.padding(16).background(.background)
            }
        }.textFieldStyle(.roundedBorder).controlSize(.regular)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: draft.dirty)
            .onChange(of: draft.folderMode) { _, _ in draft.inspectDestination() }
            .onChange(of: draft.dirty) { _, pending in
                AccessibilityNotification.Announcement(
                    pending ? "Pending changes: " + draft.pendingSummary : "Storage settings match the active library."
                ).post()
            }
            .onChange(of: draft.message) { _, message in
                if !draft.dirty && !message.isEmpty { AccessibilityNotification.Announcement(message).post() }
            }
            .sheet(
                isPresented: $draft.reviewRequested,
                onDismiss: {
                    let close = draft.closeAfterReview
                    draft.closeAfterReview = nil
                    if !draft.dirty { close?() }
                }
            ) { StorageSwitchReview(draft: draft) { draft.reviewRequested = false } }
            .sheet(
                isPresented: $generate,
                onDismiss: {
                    if generateAfterDismiss {
                        generateAfterDismiss = false
                        draft.chooseKey(generate: true, filename: keyName)
                    }
                }
            ) {
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
                        }.disabled(keyName.isEmpty || keyName.contains("/") || [".", ".."].contains(keyName))
                    }
                }.textFieldStyle(.roundedBorder).padding(20).frame(width: 480)
            }
    }
    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            StorageStatusRow(text: activeSummary, status: controller.container == nil ? .attention : .ok)
                .font(.callout)
            if controller.storage == nil && controller.container != nil {
                Text(controller.credentialPrivacyDescription).font(.caption).foregroundStyle(.secondary)
            }
            if !draft.message.isEmpty {
                Text(draft.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            FormSection(title: "Location") {
                SettingsRow(label: "Keep connections") {
                    HStack {
                        Picker("Keep connections", selection: $draft.folderMode) {
                            Text("In a folder I choose").tag(true)
                            Text("In Farcast’s app library").tag(false)
                        }.pickerStyle(.radioGroup).labelsHidden()
                        if draft.locationPending { PendingTag() }
                    }
                }
                if draft.folderMode {
                    SettingsRow(label: "Folder") {
                        SettingsPathRow(url: draft.root, isDefault: draft.isDefaultRoot)
                    }
                    HStack {
                        Button("Choose Folder…") { draft.chooseFolder(defaultFolder: false) }
                        Button("Use Default Folder…") { draft.chooseFolder(defaultFolder: true) }
                            .disabled(draft.isDefaultRoot)
                            .help("The default ~/.farcast-connections folder is hidden in Finder.")
                        revealButton(draft.root, label: "folder")
                    }
                } else {
                    Text("Connections stay in Farcast’s private app data folder.").font(.caption).foregroundStyle(
                        .secondary)
                }
            }
            FormSection(title: "Credential Protection") {
                if draft.folderMode {
                    SettingsRow(label: "Protect passwords and keys") {
                        HStack {
                            Picker("Protect passwords and keys", selection: $draft.protection) {
                                Text("Key file").tag(CredentialProtection.keyFile)
                                Text("Password").tag(CredentialProtection.password)
                                Text("Unencrypted").tag(CredentialProtection.unencrypted)
                            }.labelsHidden().disabled(draft.existingDestination)
                            InfoPopoverButton(
                                title: "Credential protection",
                                detail:
                                    "Passwords and private keys are encrypted with AES-128-GCM in key-file and password modes. Hostnames, usernames and connection names are stored as plain text. Applying a different key re-encrypts your saved credentials. Keep the old key for older backups and migration sources. Use one Farcast instance per library at a time; preferences and server trust stay on this Mac."
                            )
                            if draft.protectionPending { PendingTag() }
                        }
                    }
                    if draft.existingDestination {
                        Text(
                            "This library uses its saved protection. Use Existing Data to open it before changing protection."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if draft.protection == .keyFile { keyControls }
                    if draft.protection == .password {
                        SettingsRow(label: draft.existingDestination ? "Library password" : "New library password") {
                            SecureField("Library password", text: $draft.password)
                        }
                        if draft.needsNewPassword {
                            SettingsRow(label: "Confirm password") {
                                SecureField("Confirm new password", text: $draft.confirmation)
                            }
                        }
                        notice(
                            "Keep your library password safe",
                            detail: "If you lose it, saved passwords and private keys cannot be recovered.")
                    }
                    if draft.protection == .unencrypted {
                        notice(
                            "Credentials will not be encrypted",
                            detail: "Anyone with access to the folder can read passwords and private keys.")
                    }
                } else {
                    SettingsRow(label: "Protection") { Text("macOS Keychain with local fallback") }
                    Text("To choose key-file, password or unencrypted protection, select a folder.").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            FormSection(title: "Import") {
                HStack {
                    Text("Bring in connections and saved passwords and private keys from another folder or backup.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
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
            }
        }
    }
    private var activeSummary: String {
        guard controller.container != nil else { return "Library not open — open or unlock it in the workspace." }
        let protection = controller.storage?.manifest.protection
        let title =
            protection == .keyFile
            ? "Key file"
            : protection == .password
                ? "Password" : protection == .unencrypted ? "Unencrypted" : "Keychain with local fallback"
        let count = (try? controller.container?.mainContext.fetchCount(FetchDescriptor<SavedConnection>())) ?? 0
        return "\(draft.activeTitle) · \(title) · \(count) \(count == 1 ? "connection" : "connections")"
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.pendingSummary).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Revert") { draft.revert() }
                PrimaryActionButton(title: draft.actionTitle) {
                    draft.message = ""
                    draft.inspectDestination()
                    draft.reviewRequested = true
                }
            }
            if let issue = draft.configurationIssue {
                Label(issue, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(label: "Key file") { SettingsPathRow(url: draft.keyFile) }
            HStack {
                StorageStatusRow(
                    text: draft.keyReady ? "Key file found" : "Key file missing or access needed",
                    status: draft.keyReady ? .ok : .attention)
                Spacer()
            }.font(.caption)
            HStack {
                Menu("Change Key") {
                    Button("Use Existing Key…") { draft.chooseKey(generate: false) }
                    if !draft.existingDestination { Button("Generate New Key…") { generate = true } }
                }.fixedSize()
                Button(backupDate == nil ? "Back Up Key…" : "Back Up Again…") { backupKey() }.disabled(!draft.keyReady)
                revealButton(draft.keyFile, label: "key file")
            }
            if let date = backupDate {
                Text("Key backed up \(date.formatted(date: .abbreviated, time: .omitted)).").font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                notice(
                    "Back up your key file",
                    detail:
                        "If you lose it, saved passwords and private keys cannot be recovered. Keep the backup separate from this library."
                )
            }
            if draft.keyInsideFolder {
                notice(
                    "The key is inside the connection folder",
                    detail: "Anyone with both files can decrypt the credentials. Choose a key outside this folder.")
            }
        }
    }
    private func revealButton(_ url: URL, label: String) -> some View {
        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            .help("Reveal \(label) in Finder").accessibilityLabel("Reveal \(label) in Finder")
            .disabled(!FileManager.default.fileExists(atPath: url.path))
    }
    private func notice(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle").fontWeight(.medium)
            Text(detail).fixedSize(horizontal: false, vertical: true)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
    private var keyFingerprint: String? {
        guard let data = try? StorageFile.read(draft.keyFile, limit: 16), data.count == 16 else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var backupDate: Date? {
        _ = backupRevision
        return keyFingerprint.flatMap { controller.keyBackupDate(fingerprint: $0) }
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
            let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            controller.recordKeyBackup(fingerprint: fingerprint)
            backupRevision += 1
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
