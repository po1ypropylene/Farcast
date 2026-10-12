import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionEditor: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedWireGuard.name) private var tunnels: [SavedWireGuard]
    @Query private var saved: [SavedConnection]
    @ObservedObject var workspace: Workspace
    let request: EditorRequest
    private let loadCredential: (UUID) throws -> ConnectionCredential?
    @State private var sheetHeight: CGFloat
    @State private var showWireGuard = false
    @State private var draft: ConnectionDraft
    @State private var credential = ConnectionCredential()
    @State private var remember = true
    @State private var revealPassword = false
    @State private var selectedTab = EditorTab.general
    @State private var customResolution = false
    @FocusState private var focusedField: EditorField?
    private enum EditorField: Hashable {
        case address, port, name, username, width, height
        case folder(UUID)
    }
    private static let sheetWidth: CGFloat = 540
    private static let labelWidth: CGFloat = 128
    private static let columnGap: CGFloat = 12
    private static let contentPadding: CGFloat = 24
    @State private var fingerprint: String?
    @State private var error: String?
    init(
        workspace: Workspace, request: EditorRequest,
        loadCredential: @escaping (UUID) throws -> ConnectionCredential? = CredentialStore.load
    ) {
        self.workspace = workspace
        self.request = request
        self.loadCredential = loadCredential
        _draft = State(initialValue: request.draft)
        let parent = NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow
        _sheetHeight = State(initialValue: min(600, max(320, (parent?.contentLayoutRect.height ?? 680) - 80)))
    }
    private var title: String {
        switch request.mode {
        case .quick: return "Quick Connect"
        case .create: return "New connection"
        case .edit: return "Edit “\(request.draft.name)”"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                if request.mode == .edit {
                    Text("\(request.draft.kind.rawValue) · \(request.draft.host)")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle).help(request.draft.host)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            tabBar
            Divider()
            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, Self.contentPadding).padding(.top, 16).padding(.bottom, 16)
            }.id(selectedTab)
            Divider()
            footer
        }.buttonStyle(.bordered).controlSize(.regular).textFieldStyle(.roundedBorder)
            .frame(width: Self.sheetWidth, height: sheetHeight)
            .background(ConnectionEditorInitialFocus(clear: request.mode == .edit).frame(width: 0, height: 0))
            .sheet(isPresented: $showWireGuard) { WireGuardLibrary() }
            .onAppear {
                do { if let stored = try loadCredential(draft.id) { credential = stored } } catch {
                    self.error = error.localizedDescription
                }
                refreshFingerprint()
                if request.mode != .edit { focusedField = .address }
            }
            .onChange(of: draft.kind) { old, new in
                if draft.port == old.defaultPort { draft.port = new.defaultPort }
                credential = ConnectionCredential()
                revealPassword = false
                if new != .ssh { draft.authentication = .password }
            }
            .onChange(of: draft.authentication) { _, _ in
                credential = ConnectionCredential()
                revealPassword = false
            }
            .onChange(of: draft.endpointKey) { _, _ in refreshFingerprint() }
            .onChange(of: availableTabs) { _, tabs in
                if !tabs.contains(selectedTab) { selectedTab = .general }
            }
    }
    private var commonFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConnectionProtocolPicker(selection: $draft.kind).frame(height: 28)
            section("Server") {
                row("Address") {
                    HStack(spacing: 6) {
                        TextField("Address", text: $draft.host, prompt: Text("server.example.com or 192.168.1.10"))
                            .accessibilityLabel("Address").focused($focusedField, equals: .address)
                            .invalidBorder(hostMessage != nil)
                        Text(":").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Port", value: $draft.port, format: .number.grouping(.never))
                            .frame(width: 64).accessibilityLabel("Port").focused($focusedField, equals: .port)
                            .invalidBorder(!(1...65535).contains(draft.port))
                    }
                }
                if let message = hostMessage { inlineMessage(message) }
                if !(1...65535).contains(draft.port) { inlineMessage("Port must be between 1 and 65535.") }
                row("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Defaults to address")).accessibilityLabel("Name")
                        .focused($focusedField, equals: .name)
                }
            }
            section("Sign in") {
                row("Username") {
                    TextField(
                        "Username", text: $draft.username,
                        prompt: Text(draft.kind == .vnc ? "Optional — X509Plain only" : "Required")
                    ).accessibilityLabel(
                        "Username"
                    )
                    .focused($focusedField, equals: .username)
                    .invalidBorder(draft.validationMessage == "Enter a username.")
                }
                if draft.validationMessage == "Enter a username." { inlineMessage("Enter a username.") }
                if draft.kind == .rdp {
                    row("Domain") {
                        TextField("Domain", text: $draft.domain, prompt: Text("Optional")).accessibilityLabel("Domain")
                    }
                } else if draft.kind == .ssh {
                    row("Authentication") {
                        Picker("Authentication", selection: $draft.authentication) {
                            ForEach(SSHAuthentication.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden().accessibilityLabel("Authentication")
                    }
                }
                credentialFields
                if draft.kind == .vnc {
                    caption(
                        "Classic VNC uses the first 8 Latin-1 password bytes and does not encrypt the desktop. Use WireGuard on untrusted networks. VeNCrypt X509 modes use verified TLS."
                    )
                }
            }
            section("Network") {
                row("Connect via") {
                    Picker("Connect via", selection: tunnelSelection) {
                        Text("Direct").tag("direct")
                        ForEach(tunnels) { Text($0.name).tag($0.id.uuidString) }
                        if let id = draft.wireGuardID, !tunnels.contains(where: { $0.id == id }) {
                            Text("Unavailable profile").tag(id.uuidString)
                        }
                        Divider()
                        Text("Manage WireGuard Connections…").tag("manage")
                    }.labelsHidden().accessibilityLabel("Connect via")
                        .help(
                            "Sessions using this WireGuard profile share its tunnel. The address must be reachable inside it."
                        )
                }
            }
        }
    }
    private var tunnelSelection: Binding<String> {
        Binding(
            get: { draft.wireGuardID?.uuidString ?? "direct" },
            set: { value in
                if value == "manage" { showWireGuard = true } else { draft.wireGuardID = UUID(uuidString: value) }
            })
    }
    private var hostMessage: String? {
        guard let message = draft.validationMessage else { return nil }
        return message.contains("host name") || message.contains("server address") ? message : nil
    }
    @ViewBuilder private var credentialFields: some View {
        if draft.kind != .ssh || draft.authentication == .password {
            passwordRow("Password", placeholder: "Optional — asked when connecting")
        }
        if draft.kind == .ssh && draft.authentication == .privateKey {
            row("Private key") {
                HStack(spacing: 8) {
                    Text(credential.keyName ?? "No key selected").foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Choose Key…") { importKey() }
                }
            }
            passwordRow("Passphrase", placeholder: "Optional")
            caption("The imported key is saved with your credentials; the original file stays unchanged.")
        }
        if draft.kind == .ssh && draft.authentication == .interactive {
            caption("The server’s authentication questions will appear when you connect.")
        }
        if request.mode != .quick {
            row("") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Save credentials on this Mac", isOn: $remember)
                    Text("Keychain when available; otherwise unencrypted, owner-only local files.")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(
                            "Turn off to enter credentials each time. Local files are in your Library/Application Support folder."
                        )
                }
            }
        } else {
            caption("Credentials are used for this session only.")
        }
    }
    private func passwordRow(_ label: String, placeholder: String) -> some View {
        row(label) {
            HStack(spacing: 6) {
                Group {
                    if revealPassword {
                        TextField(label, text: $credential.password, prompt: Text(placeholder))
                    } else {
                        SecureField(label, text: $credential.password, prompt: Text(placeholder))
                    }
                }.accessibilityLabel(label)
                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                }.buttonStyle(.borderless)
                    .help(revealPassword ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
                    .accessibilityLabel(revealPassword ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
            }
        }
    }
    private enum EditorTab: String, Identifiable {
        case general, display, devices, terminal, security
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .display: return "Display"
            case .devices: return "Devices & audio"
            case .terminal: return "Terminal"
            case .security: return "Security"
            }
        }
    }
    private var availableTabs: [EditorTab] {
        var tabs: [EditorTab] =
            draft.kind == .ssh
            ? [.general, .terminal] : (draft.kind == .vnc ? [.general, .display] : [.general, .display, .devices])
        // Keep the existing ability to forget a trusted endpoint when entering a new profile.
        if request.mode == .edit || fingerprint != nil { tabs.append(.security) }
        return tabs
    }
    private var validationTab: EditorTab? {
        guard let message = draft.validationMessage else { return nil }
        if draft.kind == .rdp {
            if message.contains("Desktop dimensions") { return .display }
            if message.localizedCaseInsensitiveContains("folder") || message.contains("drive name") {
                return .devices
            }
        }
        return .general
    }
    private func revealValidation(in tab: EditorTab) {
        selectedTab = tab
        let field: EditorField?
        switch tab {
        case .display: field = !(200...8192).contains(draft.desktopWidth) ? .width : .height
        case .devices: field = draft.redirectedFolders.first.map { .folder($0.id) }
        case .general:
            if hostMessage != nil {
                field = .address
            } else if !(1...65535).contains(draft.port) {
                field = .port
            } else {
                field = .username
            }
        default: field = nil
        }
        DispatchQueue.main.async { focusedField = field }
    }
    private var tabBar: some View {
        HStack(spacing: 20) {
            ForEach(availableTabs) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(tab.title).font(.body.weight(selectedTab == tab ? .semibold : .regular))
                        if validationTab == tab {
                            Circle().fill(.red).frame(width: 5, height: 5).accessibilityHidden(true)
                        }
                    }.foregroundStyle(selectedTab == tab ? Color.primary : .secondary)
                        .padding(.vertical, 10)
                        .overlay(alignment: .bottom) {
                            if selectedTab == tab { Rectangle().fill(.tint).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(validationTab == tab ? "\(tab.title), invalid settings" : tab.title)
                    .accessibilityValue(selectedTab == tab ? "Selected" : "")
                    .help(validationTab == tab ? draft.validationMessage ?? tab.title : tab.title)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, Self.contentPadding)
    }
    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .general: commonFields
        case .terminal: terminalAppearance
        case .display:
            if draft.kind == .vnc { vncDisplay } else { display }
        case .devices: devices
        case .security: security
        }
    }
    private var vncDisplay: some View {
        VStack(spacing: 10) {
            row("Display") {
                Picker("Display", selection: $draft.displayMode) {
                    Text("Fit to window").tag(RDPDisplayMode.fit)
                    Text("100% with scrolling").tag(RDPDisplayMode.actualSize)
                }.labelsHidden().accessibilityLabel("Display")
            }
            caption("VNC uses the server’s desktop size. Fitting changes only the local view.")
            row("") { Toggle("Start in full screen", isOn: $draft.launchFullScreen) }
            caption(
                "Paste Text from Clipboard types into the focused remote application. It does not share the clipboard or files."
            )
        }
    }
    private var terminalAppearance: some View {
        VStack(spacing: 10) {
            row("Theme") {
                Picker("Theme", selection: $draft.terminalTheme) {
                    ForEach(["Midnight", "Solarized", "Paper"], id: \.self) { Text($0) }
                }.labelsHidden().accessibilityLabel("Theme")
            }
            row("Font size") {
                HStack(spacing: 6) {
                    Text("\(Int(draft.fontSize))").monospacedDigit().frame(width: 32, alignment: .trailing)
                    Text("pt").foregroundStyle(.secondary)
                    Stepper("Font size", value: $draft.fontSize, in: 9...32)
                        .labelsHidden().accessibilityLabel("Font size")
                        .accessibilityValue("\(Int(draft.fontSize)) points")
                    Spacer(minLength: 0)
                }
            }
        }
    }
    private var display: some View {
        VStack(spacing: 10) {
            windowedDisplayOptions.disabled(draft.launchFullScreen)
            if draft.launchFullScreen {
                caption(
                    "Full screen uses the selected displays’ sizes. Window options are kept for windowed connections.")
            }
            Divider().padding(.vertical, 4)
            row("") { Toggle("Open in full screen", isOn: $draft.launchFullScreen) }
            row("") {
                Toggle("Use all monitors", isOn: $draft.useAllMonitors).disabled(!draft.launchFullScreen)
            }
            caption("All monitors use their screen sizes and arrangement instead of the selected resolution.")
            row("") { Toggle("Optimize for Retina", isOn: $draft.retinaDisplay) }
            caption("With Retina on, sizes use Mac points; remote pixels follow backing density.")
                .help(
                    "Retina multiplies the selected logical size by the display’s backing density and requests matching Windows UI scale. Each remote monitor is limited to 8192 pixels per side. Server DPI behavior varies; larger desktops use more memory and bandwidth. Changes apply after reconnecting."
                )
        }
    }
    private var windowedDisplayOptions: some View {
        VStack(spacing: 10) {
            row("Display") {
                Picker("Display", selection: displaySelection) {
                    Text("Fit to window").tag("fit")
                    Text("Resize with window").tag("resize")
                    Text("100% with scrolling").tag("actualSize")
                    Text("Match window at connection").tag("matchWindow")
                }.labelsHidden().accessibilityLabel("Display")
            }
            caption(displayCaption).help(displayExplanation)
            if draft.displayMode != .matchWindow {
                row(
                    draft.retinaDisplay
                        ? "Logical size" : (draft.displayMode == .actualSize ? "Resolution" : "Initial resolution")
                ) {
                    Picker("Resolution", selection: resolutionSelection) {
                        ForEach(RDPResolutionPreset.all) { Text($0.title).tag($0.id) }
                        Divider()
                        Text("Custom…").tag("custom")
                    }.labelsHidden().accessibilityLabel("Resolution")
                }
                if resolutionSelection.wrappedValue == "custom" {
                    row("Custom size") {
                        HStack(spacing: 6) {
                            TextField("Width", value: $draft.desktopWidth, format: .number.grouping(.never))
                                .accessibilityLabel("Desktop width").focused($focusedField, equals: .width)
                                .frame(minWidth: 0, idealWidth: 100, maxWidth: .infinity)
                                .invalidBorder(!(200...8192).contains(draft.desktopWidth))
                            Text("×").foregroundStyle(.secondary).accessibilityHidden(true)
                            TextField("Height", value: $draft.desktopHeight, format: .number.grouping(.never))
                                .accessibilityLabel("Desktop height").focused($focusedField, equals: .height)
                                .frame(minWidth: 0, idealWidth: 100, maxWidth: .infinity)
                                .invalidBorder(!(200...8192).contains(draft.desktopHeight))
                            Text(draft.retinaDisplay ? "pt" : "px").foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                if !(200...8192).contains(draft.desktopWidth) || !(200...8192).contains(draft.desktopHeight) {
                    inlineMessage("Desktop dimensions must be between 200 and 8192 pixels.")
                }
            }
        }
    }
    private var resolutionSelection: Binding<String> {
        Binding(
            get: {
                if customResolution { return "custom" }
                return RDPResolutionPreset.matching(width: draft.desktopWidth, height: draft.desktopHeight)?.id
                    ?? "custom"
            },
            set: { value in
                if value == "custom" {
                    customResolution = true
                } else if let preset = RDPResolutionPreset.all.first(where: { $0.id == value }) {
                    draft.desktopWidth = preset.width
                    draft.desktopHeight = preset.height
                    customResolution = false
                }
            })
    }
    private var displayCaption: String {
        switch displaySelection.wrappedValue {
        case "resize": return "Resize with the window when supported; otherwise scale to fit."
        case "actualSize":
            return draft.retinaDisplay
                ? "Match backing pixels; scroll to see the full desktop."
                : "One remote pixel per Mac point; scroll to see the full desktop."
        case "matchWindow": return "Use the window’s initial size until you reconnect."
        default: return "Scale the desktop to fit the window."
        }
    }
    private var displayExplanation: String {
        displaySelection.wrappedValue == "resize"
            ? "Resize the remote desktop with the window when supported; otherwise scale to fit."
            : draft.displayMode.explanation
    }
    // Presentation only: retain all existing stored display modes and resolution controls.
    private var displaySelection: Binding<String> {
        Binding(
            get: { draft.displayMode == .fit && draft.dynamicResolution ? "resize" : draft.displayMode.rawValue },
            set: { value in
                if value == "resize" {
                    draft.displayMode = .fit
                    draft.dynamicResolution = true
                } else {
                    draft.displayMode = RDPDisplayMode(rawValue: value) ?? .fit
                    if value == "fit" { draft.dynamicResolution = false }
                }
            })
    }
    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Clipboard") {
                row("") {
                    Toggle("Share clipboard", isOn: $draft.clipboard)
                        .help(
                            "Use ⌘C/⌘V on this Mac or Control+C/Control+V in Windows. Remote files download before Finder can paste them."
                        )
                }
                caption("Copy and paste text and files between this Mac and the remote desktop.")
            }
            section("Audio") {
                row("") { Toggle("Play remote sound on this Mac", isOn: $draft.audioPlayback) }
            }.padding(.top, 10)
            section("Local folders") {
                if draft.redirectedFoldersUnavailable {
                    Button("Reset unavailable folder settings") {
                        draft.redirectedFolders = []
                        draft.redirectedFoldersUnavailable = false
                    }
                }
                ForEach($draft.redirectedFolders) { $folder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            TextField("Drive name", text: $folder.name, prompt: Text("Drive name"))
                                .accessibilityLabel("Drive name").focused($focusedField, equals: .folder(folder.id))
                                .invalidBorder(folder.validationMessage != nil)
                            Toggle("Read-only", isOn: $folder.readOnly)
                                .fixedSize()
                                .help(
                                    "Turning off Read-only lets the server create, change and delete this folder’s contents."
                                )
                                .accessibilityLabel("Read-only access for \(folder.name)")
                            Button {
                                draft.redirectedFolders.removeAll { $0.id == folder.id }
                            } label: {
                                Image(systemName: "minus.circle").frame(width: 24, height: 24)
                            }.buttonStyle(.borderless).help("Remove \(folder.name)")
                                .accessibilityLabel("Remove redirected folder \(folder.name)")
                        }
                        Text(RDPFolderPicker.displayPath(for: folder))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityLabel("Local folder: \(RDPFolderPicker.displayPath(for: folder))")
                        if let message = folder.validationMessage {
                            Text(message).font(.caption).foregroundStyle(.red)
                        }
                        Button("Choose another folder…") { chooseRedirectedFolder(replacing: folder.id) }
                            .accessibilityLabel("Choose another local folder for \(folder.name)")
                    }
                }
                Button("Add Folder…") { chooseRedirectedFolder(replacing: nil) }
                    .disabled(draft.redirectedFolders.count >= 16)
                Text(verbatim: "Appear in Windows under This PC and \\\\tsclient.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 10)
        }
    }
    private var security: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fingerprint {
                Text(fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Forget trusted identity") {
                    workspace.trust.forget(draft.endpointKey)
                    refreshFingerprint()
                }
            } else {
                Text("Farcast will ask you to verify this server the first time you connect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func refreshFingerprint() { fingerprint = workspace.trust.fingerprint(for: draft.endpointKey) }
    private var needsReconnectNote: Bool {
        guard request.mode == .edit,
            workspace.sessions.contains(where: { $0.profile.id == draft.id && $0.state.active })
        else { return false }
        let original = request.draft
        return draft.launchFullScreen != original.launchFullScreen || draft.useAllMonitors != original.useAllMonitors
            || draft.retinaDisplay != original.retinaDisplay
            || draft.displayMode != original.displayMode || draft.dynamicResolution != original.dynamicResolution
            || draft.desktopWidth != original.desktopWidth || draft.desktopHeight != original.desktopHeight
            || draft.clipboard != original.clipboard || draft.audioPlayback != original.audioPlayback
            || draft.redirectedFolders != original.redirectedFolders
            || draft.terminalTheme != original.terminalTheme || draft.fontSize != original.fontSize
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let message = draft.validationMessage, let tab = validationTab {
                        Button {
                            revealValidation(in: tab)
                        } label: {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.buttonStyle(.plain).help("Show the field that needs attention in \(tab.title).")
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if request.mode != .quick {
                        Button("Save") { commit(connect: false) }.disabled(draft.validationMessage != nil)
                    }
                    PrimaryActionButton(title: request.mode == .quick ? "Connect" : "Save & Connect") {
                        commit(connect: true)
                    }.keyboardShortcut(.defaultAction).disabled(draft.validationMessage != nil)
                }.fixedSize()
            }
            if needsReconnectNote {
                Text("Changes apply when you reconnect.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            Text(label).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true).frame(width: Self.labelWidth, alignment: .trailing)
            content().frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, -2)
            content()
        }
    }
    private func caption(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2).help(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, Self.labelWidth + Self.columnGap)
    }
    private func inlineMessage(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, Self.labelWidth + Self.columnGap)
    }
    private func chooseRedirectedFolder(replacing id: UUID?) {
        do {
            let folders = try RDPFolderPicker.pick()
            if let id, let first = folders.first, let index = draft.redirectedFolders.firstIndex(where: { $0.id == id })
            {
                draft.redirectedFolders[index].bookmark = first.bookmark
            } else {
                draft.redirectedFolders.append(contentsOf: folders)
            }
        } catch { self.error = "Folder access could not be saved. Choose the folder again." }
    }
    private func importKey() {
        do {
            if let imported = try PrivateKeyPicker.pick() {
                credential.privateKey = imported.data
                credential.keyName = imported.name
            }
        } catch { self.error = error.localizedDescription }
    }
    private func commit(connect: Bool) {
        draft.normalize()
        guard draft.validationMessage == nil else {
            error = draft.validationMessage
            return
        }
        if draft.kind == .ssh && draft.authentication == .privateKey && credential.privateKey == nil {
            error = "Choose a private key first."
            return
        }
        if let id = draft.wireGuardID, !tunnels.contains(where: { $0.id == id }) {
            error = WireGuardError.unavailable.localizedDescription
            return
        }
        let hasCredential =
            draft.authentication == .privateKey ? credential.privateKey != nil : !credential.password.isEmpty
        do {
            if request.mode != .quick {
                if remember && hasCredential && draft.authentication != .interactive {
                    try CredentialStore.save(credential, for: draft.id)
                } else {
                    try CredentialStore.delete(draft.id)
                }
                if let existing = saved.first(where: { $0.id == draft.id }) {
                    existing.update(from: draft)
                } else {
                    context.insert(SavedConnection(draft: draft))
                }
                try context.save()
            }
            let snapshot = draft
            let secret = credential
            dismiss()
            if connect {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    workspace.connect(
                        snapshot, credential: hasCredential ? secret : nil, persistent: request.mode != .quick)
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

extension View {
    fileprivate func invalidBorder(_ invalid: Bool) -> some View {
        overlay {
            if invalid {
                RoundedRectangle(cornerRadius: 5).stroke(Color.red, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}

private struct ConnectionProtocolPicker: NSViewRepresentable {
    @Binding var selection: RemoteProtocol
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: RemoteProtocol.allCases.map(\.rawValue), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectProtocol(_:)))
        control.controlSize = .regular
        control.segmentDistribution = .fill
        control.setAccessibilityLabel("Protocol")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = RemoteProtocol.allCases.firstIndex(of: selection) ?? 0
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 472, height: 28)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: ConnectionProtocolPicker
        init(_ parent: ConnectionProtocolPicker) { self.parent = parent }
        @objc func selectProtocol(_ control: NSSegmentedControl) {
            guard RemoteProtocol.allCases.indices.contains(control.selectedSegment) else { return }
            parent.selection = RemoteProtocol.allCases[control.selectedSegment]
        }
    }
}

// Clear automatic text selection once when an edit sheet joins its presenting window.
private struct ConnectionEditorInitialFocus: NSViewRepresentable {
    let clear: Bool
    func makeNSView(context: Context) -> FocusView { FocusView(clear: clear) }
    func updateNSView(_ nsView: FocusView, context: Context) {}
    final class FocusView: NSView {
        private let clear: Bool
        private var applied = false
        init(clear: Bool) {
            self.clear = clear
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard clear, !applied, let window else { return }
            applied = true
            DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
        }
    }
}
