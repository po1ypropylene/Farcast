import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WireGuardLibrary: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedWireGuard.name) private var profiles: [SavedWireGuard]
    @State private var selectedID: UUID?
    @State private var draftID = UUID()
    @State private var draft = VPNProfileDraft()
    @State private var baseline = VPNProfileDraft()
    @State private var creating = false
    @State private var loaded = false
    @State private var error: String?
    @State private var attemptedSave = false
    @State private var fieldErrors: [String: String] = [:]
    @State private var editorIdentity = UUID()
    @State private var ignoredBlurField: String?
    @State private var advanced = false
    @State private var deleting = false
    @State private var pending: Navigation?
    @State private var confirmNavigation = false
    @State private var confirmProtocol = false
    @State private var dropTarget = false
    @FocusState private var focus: String?

    private let loadCredential: (UUID) throws -> ConnectionCredential?
    private let saveCredential: (ConnectionCredential, UUID) throws -> Void
    private let deleteCredential: (UUID) throws -> Void

    init(
        loadCredential: @escaping (UUID) throws -> ConnectionCredential? = CredentialStore.load,
        saveCredential: @escaping (ConnectionCredential, UUID) throws -> Void = {
            try CredentialStore.save($0, for: $1)
        },
        deleteCredential: @escaping (UUID) throws -> Void = CredentialStore.delete
    ) {
        self.loadCredential = loadCredential
        self.saveCredential = saveCredential
        self.deleteCredential = deleteCredential
    }

    private enum Navigation {
        case profile(UUID)
        case new, done
    }
    private var dirty: Bool { loaded && (creating || draft != baseline) }
    private var issues: [String: String] {
        draft.issues(existingNames: profiles.filter { $0.id != draftID }.map(\.name))
    }
    private var selection: Binding<UUID?> {
        Binding(
            get: { loaded ? draftID : selectedID },
            set: { id in
                if let id, id != draftID { request(.profile(id)) }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("VPN Connections", systemImage: "network.badge.shield.half.filled").font(.title2)
                Spacer()
                Button("Done") { request(.done) }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                if loaded {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                profileSection
                                importStrip
                                if draft.configuration.isOpenVPN { openVPNSections } else { wireGuardSections }
                                Label(
                                    "Secrets use Keychain when available, otherwise owner-only local files that are not encrypted.",
                                    systemImage: "lock"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: 560, alignment: .leading).padding(20)
                        }
                        .onChange(of: attemptedSave) { _, attempted in
                            if attempted { revealIssue(reader) }
                        }
                        .onChange(of: focus) { old, _ in
                            if let old {
                                if old == ignoredBlurField {
                                    ignoredBlurField = nil
                                } else {
                                    fieldErrors[old] = issues[old]
                                }
                            }
                        }
                        .onChange(of: validationRequest) { _, _ in revealIssue(reader) }
                    }
                } else {
                    ContentUnavailableView(
                        "No VPN profiles", systemImage: "network.badge.shield.half.filled",
                        description: Text("Create a profile to use with your Farcast connections.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use this profile by choosing it under “Connect via” when editing a connection.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
                    }
                    if attemptedSave && !issues.isEmpty {
                        Text("Check \(issues.count) highlighted field\(issues.count == 1 ? "" : "s").")
                            .font(.caption).foregroundStyle(.red)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if dirty { Button("Revert") { revert() } }
                Button("Save") { _ = save() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command).disabled(!dirty)
            }.padding(16)
        }
        .buttonStyle(.bordered).controlSize(.regular).frame(width: 820, height: 740)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(dirty)
        .onAppear {
            guard !loaded else { return }
            if let first = profiles.first { load(first.id) }
        }
        .alert("Save changes to this VPN profile?", isPresented: $confirmNavigation) {
            Button("Save") { if save() { completeNavigation() } }
            Button("Discard", role: .destructive) { completeNavigation() }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("Your unsaved changes will be lost if you discard them.")
        }
        .alert("Change VPN protocol?", isPresented: $confirmProtocol) {
            Button("Change Protocol", role: .destructive) { changeProtocol() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This clears the current protocol’s configuration and credentials from this draft. Save to apply the change."
            )
        }
        .alert("Delete this VPN profile?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Unsaved edits will be discarded. Connections using this profile will refuse to connect until you choose another VPN or Direct. Active sessions continue until disconnected."
            )
        }
    }

    @State private var validationRequest = UUID()
    private func revealIssue(_ reader: ScrollViewProxy) {
        guard let first = draft.fieldOrder.first(where: { issues[$0] != nil }) else { return }
        if ["dns", "mtu", "presharedKey", "keepalive"].contains(first) { advanced = true }
        DispatchQueue.main.async {
            withAnimation { reader.scrollTo(first, anchor: .center) }
            focus = first
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                ForEach(profiles) { profile in
                    profileRow(
                        name: loaded && profile.id == draftID ? draft.name : profile.name,
                        protocolName: loaded && profile.id == draftID
                            ? draft.configuration.protocolName
                            : ((try? profile.configuration().protocolName) ?? "Unavailable"),
                        edited: profile.id == draftID && dirty
                    ).tag(profile.id)
                }
                if creating {
                    profileRow(name: draft.name, protocolName: draft.configuration.protocolName, edited: true).tag(
                        draftID)
                }
            }.listStyle(.sidebar)
            if profiles.isEmpty && !creating {
                Text("No VPN profiles").font(.callout).foregroundStyle(.secondary).padding(12)
            }
            HStack {
                Button("New", systemImage: "plus") { request(.new) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                    .disabled(!loaded)
            }.padding(12)
        }.frame(width: 210)
    }
    private func profileRow(name: String, protocolName: String, edited: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network.badge.shield.half.filled")
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Untitled VPN" : name).lineLimit(1)
                Text(protocolName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if edited { Image(systemName: "circle.fill").font(.system(size: 6)).accessibilityLabel("Unsaved changes") }
        }.padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(name.isEmpty ? "Untitled VPN" : name), \(protocolName)\(edited ? ", Unsaved changes" : "")")
    }
    private var profileSection: some View {
        FormSection(title: "Profile") {
            field("Name *", "name", $draft.name, prompt: "Profile name")
            FormRow(label: "Protocol") {
                Picker(
                    "Protocol",
                    selection: Binding(
                        get: { draft.configuration.isOpenVPN },
                        set: { value in
                            guard value != draft.configuration.isOpenVPN else { return }
                            if hasProtocolContent { confirmProtocol = true } else { changeProtocol() }
                        })
                ) {
                    Text("WireGuard").tag(false)
                    Text("OpenVPN").tag(true)
                }.labelsHidden()
            }
        }
    }
    private var hasProtocolContent: Bool {
        var value = draft
        value.name = "Untitled VPN"
        value.configuration.openVPN = nil
        return value != VPNProfileDraft()
    }
    private func changeProtocol() {
        let wasOpenVPN = draft.configuration.isOpenVPN
        let name = draft.name
        withAnimation(.easeInOut(duration: 0.15)) {
            draft = VPNProfileDraft()
            draft.name = name
            draft.configuration.openVPN = !wasOpenVPN
        }
        advanced = false
        fieldErrors = [:]
        attemptedSave = false
        error = nil
    }
    private var importStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: imported ? "checkmark.circle" : "square.and.arrow.down")
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        draft.importedFilename.map { "Imported from \($0)" }
                            ?? (imported
                                ? "Saved OpenVPN configuration"
                                : "Drop a \(draft.configuration.isOpenVPN ? ".ovpn" : ".conf") file here")
                    )
                    .lineLimit(2)
                    if draft.configuration.isOpenVPN,
                        let parsed = try? OpenVPNImport.parse(Data(draft.openVPNProfile.utf8))
                    {
                        Text(parsed.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    } else if !imported && !draft.configuration.isOpenVPN {
                        Text("Or fill in the fields below.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button(imported ? "Replace…" : "Import…") { chooseImport() }
                    .focused($focus, equals: "import")
                    .accessibilityLabel(imported ? "Replace VPN configuration" : "Import VPN configuration")
            }
            if let issue = visibleIssue("import") {
                Label(issue, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.red)
            }
            if draft.configuration.isOpenVPN {
                Text("Only Farcast sessions use this VPN.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("One peer per profile. No scripts or macOS network changes. ListenPort is automatic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                dropTarget ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    .secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard urls.count == 1, let url = urls.first else { return false }
                importFile(url)
                return true
            } isTargeted: {
                dropTarget = $0
            }
            .id("import")
    }
    private var imported: Bool {
        draft.importedFilename != nil || (draft.configuration.isOpenVPN && !draft.openVPNProfile.isEmpty)
    }

    private var wireGuardSections: some View {
        Group {
            FormSection(title: "Interface") {
                field(
                    "Address *", "address", $draft.configuration.addresses, prompt: "10.0.0.2/32",
                    caption: "Comma-separated for multiple addresses")
                field(
                    "Private key *", "privateKey", $draft.privateKey, prompt: "44-character base64 key", secret: true,
                    key: true)
            }
            FormSection(title: "Peer") {
                field(
                    "Public key *", "publicKey", $draft.configuration.publicKey, prompt: "44-character base64 key",
                    key: true)
                field("Endpoint *", "endpoint", $draft.configuration.endpoint, prompt: "vpn.example.com:51820")
                field("Allowed IPs *", "allowedIPs", $draft.configuration.allowedIPs, prompt: "10.0.0.0/24")
            }
            DisclosureGroup(isExpanded: $advanced) {
                VStack(spacing: 8) {
                    field(
                        "DNS servers", "dns", $draft.configuration.dns, prompt: "1.1.1.1, 1.0.0.1",
                        caption: "IP addresses, comma-separated")
                    field(
                        "MTU", "mtu", $draft.mtu, prompt: "1420", caption: "Default: 1420; supported range: 1280–1500")
                    field("Preshared key", "presharedKey", $draft.presharedKey, secret: true, key: true)
                    field(
                        "Keepalive", "keepalive", $draft.keepalive, prompt: "25",
                        caption: "Seconds; 0 disables keepalive")
                    Text(
                        "DNS inside Allowed IPs uses the VPN; other DNS uses this Mac’s network. Active sessions share the tunnel; disconnect them before applying changes."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            } label: {
                Text("Advanced").font(.body.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            Text("* Required").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var openVPNSections: some View {
        Group {
            FormSection(title: "Authentication") {
                field("Username", "username", $draft.username)
                field("Password", "password", $draft.password, secret: true)
                field(
                    "Key passphrase", "passphrase", $draft.passphrase, caption: "Private-key passphrase, if required",
                    secret: true)
                Text("Only needed if your profile requires it.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup {
                Text(
                    "Supported: TUN over UDP or TCP, inline CA, certificate/key or username/password authentication.\nUnsupported: scripts, external files, TAP, compression, proxies, interactive MFA and route exclusions."
                )
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            } label: {
                Text("Supported features").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
        }
    }
    private func field(
        _ label: String, _ id: String, _ text: Binding<String>, prompt: String = "Optional",
        caption: String = "", secret: Bool = false, key: Bool = false
    ) -> some View {
        FormTextField(
            label: label, id: id, text: text, prompt: prompt, caption: caption,
            error: visibleIssue(id), secret: secret, key: key,
            selectionRequest: creating && id == "name" ? draftID : nil, focus: $focus
        ) {
            let order = draft.fieldOrder
            if let index = order.firstIndex(of: id), index + 1 < order.count {
                let next = order[index + 1]
                if ["dns", "mtu", "presharedKey", "keepalive"].contains(next) { advanced = true }
                DispatchQueue.main.async { focus = next }
            } else {
                focus = nil
            }
        }
        .id(secret ? "\(id)-\(editorIdentity)" : id)
    }
    private func visibleIssue(_ id: String) -> String? { fieldErrors[id] }

    private func request(_ navigation: Navigation) {
        pending = navigation
        if dirty { confirmNavigation = true } else { completeNavigation() }
    }
    private func completeNavigation() {
        guard let navigation = pending else { return }
        pending = nil
        switch navigation {
        case .done: dismiss()
        case .new: newProfile()
        case .profile(let id): load(id)
        }
    }
    private func newProfile() {
        selectedID = nil
        draftID = UUID()
        draft = VPNProfileDraft()
        baseline = draft
        creating = true
        loaded = true
        clearFeedback()
    }
    private func clearFeedback() {
        ignoredBlurField = focus
        editorIdentity = UUID()
        error = nil
        attemptedSave = false
        fieldErrors = [:]
        advanced = false
        focus = nil
    }
    private func revert() {
        if creating {
            if let first = profiles.first {
                load(first.id)
            } else {
                loaded = false
                creating = false
                clearFeedback()
            }
        } else {
            draft = baseline
            clearFeedback()
        }
    }
    private func load(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            let configuration = try profile.configuration()
            let secret = try loadCredential(id)
            var value = VPNProfileDraft()
            value.name = profile.name
            value.configuration = configuration
            value.mtu = String(configuration.mtu)
            value.keepalive = String(configuration.keepalive)
            value.privateKey = secret?.wireGuardPrivateKey ?? ""
            value.presharedKey = secret?.wireGuardPresharedKey ?? ""
            value.openVPNProfile = secret?.openVPNProfile ?? ""
            value.username = secret?.openVPNUsername ?? ""
            value.password = secret?.password ?? ""
            value.passphrase = secret?.openVPNPassphrase ?? ""
            draftID = id
            selectedID = id
            draft = value
            baseline = value
            creating = false
            loaded = true
            clearFeedback()
        } catch { self.error = "Could not load this VPN profile or its credentials." }
    }
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "Import \(draft.configuration.protocolName) Configuration"
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: draft.configuration.isOpenVPN ? "ovpn" : "conf") ?? .data
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }
    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard url.isFileURL, url.pathExtension.lowercased() == (draft.configuration.isOpenVPN ? "ovpn" : "conf"),
                (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max)
                    <= (draft.configuration.isOpenVPN ? 262_144 : 65_536)
            else { throw WireGuardError.invalidImport }
            let data = try Data(contentsOf: url)
            if draft.configuration.isOpenVPN {
                draft.openVPNProfile = try OpenVPNImport.parse(data).profile
            } else {
                let imported = try WireGuardImport.parse(data)
                draft.configuration = imported.configuration
                draft.privateKey = imported.privateKey
                draft.presharedKey = imported.presharedKey
                draft.mtu = String(imported.configuration.mtu)
                draft.keepalive = String(imported.configuration.keepalive)
            }
            draft.importedFilename = url.lastPathComponent
            if draft.name.isEmpty || draft.name == "Untitled VPN" {
                draft.name = url.deletingPathExtension().lastPathComponent
            }
            error = nil
        } catch {
            self.error =
                draft.configuration.isOpenVPN
                ? OpenVPNError.invalidImport.localizedDescription : WireGuardError.invalidImport.localizedDescription
        }
    }
    @discardableResult private func save() -> Bool {
        attemptedSave = true
        fieldErrors = issues
        guard issues.isEmpty else {
            validationRequest = UUID()
            return false
        }
        do {
            var configuration = draft.configuration
            if !configuration.isOpenVPN {
                configuration.mtu = Int(draft.mtu) ?? 1420
                configuration.keepalive = Int(draft.keepalive) ?? 25
            }
            let metadata = try JSONEncoder().encode(configuration)
            let secret =
                configuration.isOpenVPN
                ? ConnectionCredential(
                    password: draft.password, openVPNProfile: draft.openVPNProfile,
                    openVPNUsername: draft.username, openVPNPassphrase: draft.passphrase)
                : ConnectionCredential(wireGuardPrivateKey: draft.privateKey, wireGuardPresharedKey: draft.presharedKey)
            try saveCredential(secret, draftID)
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = profiles.first(where: { $0.id == draftID }) {
                existing.name = name
                existing.configurationData = metadata
            } else {
                context.insert(try SavedWireGuard(id: draftID, name: name, configuration: configuration))
            }
            try context.save()
            draft.name = name
            draft.configuration = configuration
            selectedID = draftID
            creating = false
            baseline = draft
            error = nil
            attemptedSave = false
            fieldErrors = [:]
            return true
        } catch {
            context.rollback()
            self.error = "Could not save this VPN profile. Check local storage and key access."
            return false
        }
    }
    private func delete() {
        if creating {
            revert()
            return
        }
        guard let id = selectedID, let profile = profiles.first(where: { $0.id == id }) else { return }
        do {
            try deleteCredential(id)
            context.delete(profile)
            try context.save()
            selectedID = nil
            loaded = false
            creating = false
            draft = VPNProfileDraft()
            baseline = draft
            clearFeedback()
            // Retain dangling connection IDs: deletion must never select direct networking.
            if let next = profiles.first(where: { $0.id != id }) { load(next.id) }
        } catch {
            context.rollback()
            self.error = "Could not delete this VPN profile."
        }
    }
}
