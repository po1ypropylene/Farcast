import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedConnection.name) private var connections: [SavedConnection]
    @Query(sort: \ConnectionFolder.order) private var folders: [ConnectionFolder]
    @Query(sort: \SavedWireGuard.name) private var tunnels: [SavedWireGuard]
    @ObservedObject var workspace: Workspace
    @State private var search = ""
    @State private var selectedProfileID: UUID?
    @FocusState private var sidebarFocused: Bool
    @State private var folderName = ""
    @State private var showFolderEditor = false
    @State private var editingFolder: ConnectionFolder?
    @State private var newFolderParentID: UUID?
    @State private var sshConfigImport: SSHConfigImport?
    @State private var showSSHConfigImport = false
    @State private var infoConnection: SavedConnection?
    @State private var deletingFolder: ConnectionFolder?
    @AppStorage("sidebar.connectionsExpanded") private var connectionsExpanded = true
    @State private var deletingConnection: SavedConnection?
    private var filtered: [SavedConnection] {
        connections.filter {
            search.isEmpty
                || "\($0.name) \($0.host) \($0.username) \($0.protocolName) \($0.notes) \(folderPath($0.folderID))"
                    .localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 38, height: 38).foregroundStyle(.tint)
                    Text("Farcast").font(.headline)
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 14)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search connections", text: $search).textFieldStyle(.plain)
                    if !search.isEmpty {
                        IconActionButton(title: "Clear search", symbol: "xmark.circle.fill") {
                            search = ""
                        }
                    }
                }.frame(minHeight: 24).padding(.horizontal, 10).background(
                    .quaternary, in: RoundedRectangle(cornerRadius: 8)
                ).padding(.horizontal, 14)
                    .padding(.bottom, 12)
                List(selection: $selectedProfileID) {
                    ForEach(rootFolders) { folder in folderTree(folder, ancestors: []) }
                    if !ungrouped.isEmpty {
                        Section {
                            if connectionsExpanded || !search.isEmpty {
                                ForEach(ungrouped) { connectionRow($0) }
                            }
                        } header: {
                            SidebarSectionHeader(title: "Connections", expanded: $connectionsExpanded)
                        }
                        .dropDestination(for: String.self) { values, _ in return move(values, to: nil) }
                    }
                }.listStyle(.sidebar)
                    .overlayPreferenceValue(SidebarContentBoundsKey.self) { anchors in
                        GeometryReader { geometry in
                            let bottom = anchors.map { geometry[$0].maxY }.max() ?? 0
                            let top = min(geometry.size.height, max(0, bottom))
                            SidebarRootDropTarget { move($0, to: nil) }
                                .contextMenu { addMenuItems }
                                .frame(height: geometry.size.height - top)
                                .offset(y: top)
                        }
                    }
                    .focused($sidebarFocused)
                    .onKeyPress(.return) {
                        guard workspace.editor == nil,
                            let selected = connections.first(where: { $0.id == selectedProfileID })
                        else { return .ignored }
                        connect(selected)
                        return .handled
                    }
                Divider()
                HStack {
                    Menu {
                        addMenuItems
                    } label: {
                        Label("Add", systemImage: "plus").frame(minWidth: 70, minHeight: 24).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).controlSize(.regular).frame(minWidth: 70, minHeight: 24)
                    Spacer()
                    Text("\(connections.count) connections").font(.callout).foregroundStyle(.secondary)
                }.padding(14)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 400)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.attachedSessions.isEmpty {
                    ScrollView(.horizontal) {
                        Group {
                            HStack(spacing: 4) {
                                ForEach(workspace.attachedSessions) { session in
                                    SessionTab(session: session, workspace: workspace)
                                        .draggable(session.id.uuidString)
                                        .dropDestination(for: String.self) { values, _ in
                                            guard let first = values.first, let id = UUID(uuidString: first) else {
                                                return false
                                            }
                                            workspace.reorder(id, before: session.id)
                                            return true
                                        }
                                }
                            }.padding(.horizontal, ConnectionFormLayout.inset).padding(.top, 6)
                        }
                    }.scrollIndicators(.hidden)
                    Divider()
                }
                if let session = workspace.selectedSession {
                    SessionDetailsLayout(
                        session: session, workspace: workspace, isPresented: $workspace.showInspector)
                } else {
                    overview
                }
            }.background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            workspace.editor = EditorRequest(draft: ConnectionDraft(), mode: .quick)
                        } label: {
                            Label {
                                Text("Quick Connect")
                            } icon: {
                                Image(systemName: "bolt.fill").sessionActionColor(.quickConnect)
                            }.labelStyle(.titleAndIcon)
                        }.help("Quick Connect (⌘K)").accessibilityLabel("Quick Connect")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let session = workspace.selectedSession {
                            Button {
                                workspace.requestReconnect(session)
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                                    .sessionActionColor(.reconnect)
                            }.help("Reconnect (⇧⌘R)").accessibilityLabel("Reconnect")
                            SessionDisconnectButton(session: session, workspace: workspace)
                        }
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let session = workspace.selectedSession {
                            if session.profile.kind != .ssh {
                                SessionFullScreenButton(session: session)
                            } else {
                                Button {
                                    NSApp.keyWindow?.toggleFullScreen(nil)
                                } label: {
                                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right").labelStyle(
                                        .iconOnly
                                    ).sessionActionColor(.fullScreen)
                                }.help("Full Screen (⌃⌘F)").accessibilityLabel("Full Screen")
                            }
                            Button {
                                workspace.showInspector.toggle()
                            } label: {
                                Label("Connection Details", systemImage: "sidebar.right").labelStyle(.iconOnly)
                                    .sessionActionColor(.details)
                            }.help("Connection Details (⌥⌘I)").accessibilityLabel("Connection Details")
                            Button {
                                workspace.popOut(session) { slot in
                                    NSHostingView(rootView: DetachedSessionView(workspace: workspace, slot: slot))
                                }
                            } label: {
                                Label("Pop Out Session", systemImage: "macwindow.on.rectangle").labelStyle(
                                    .iconOnly
                                ).sessionActionColor(.popOut)
                            }.help("Pop Out Session (⇧⌘O)").accessibilityLabel("Pop Out Session")
                        }
                    }
                }
        }
        .background(WorkspaceWindowRegistration(workspace: workspace))
        .modifier(SessionActionConfirmation(workspace: workspace))
        .buttonStyle(.automatic)
        .navigationTitle(workspace.selectedSession?.profile.name ?? "Workspace")
        .navigationSubtitle(
            workspace.selectedSession.map { session in
                let destination =
                    "\(session.profile.username.isEmpty ? "" : session.profile.username + "@")\(session.profile.host)"
                let tunnel = tunnels.first { $0.id == session.profile.wireGuardID }
                return destination + (tunnel.map { " · via " + $0.name } ?? "")
            } ?? ""
        )
        .frame(minWidth: 900, minHeight: 660)
        .sheet(item: $workspace.testServerImport) { request in
            TestServerImportView(workspace: workspace, document: request.document)
        }
        .popover(item: $infoConnection) { connection in
            SidebarConnectionInfo(
                connection: connection, folder: folderPath(connection.folderID),
                tunnel: tunnels.first { $0.id == connection.wireGuardID })
        }
        .sheet(isPresented: $showSSHConfigImport) {
            if let document = sshConfigImport {
                SSHConfigImportView(document: document) { workspace.error = $0 }
            }
        }
        .sheet(isPresented: $workspace.showWireGuard) { WireGuardLibrary() }
        .sheet(isPresented: $workspace.showLibraryImport) { ExistingLibraryImportView(workspace: workspace) }
        .sheet(
            item: Binding(
                get: { workspace.focusedDetachedSlot == nil ? workspace.editor : nil },
                set: { if workspace.focusedDetachedSlot == nil { workspace.editor = $0 } })
        ) { request in
            ConnectionEditor(workspace: workspace, request: request)
        }
        .sheet(
            item: Binding(
                get: { workspace.prompts.first { !workspace.detachedSessions.values.contains($0.sessionID) } },
                set: { next in
                    if next == nil,
                        let prompt = workspace.prompts.first(where: {
                            !workspace.detachedSessions.values.contains($0.sessionID)
                        })
                    {
                        workspace.answer(prompt, value: nil)
                    }
                })
        ) { prompt in PromptSheet(workspace: workspace, prompt: prompt).id(prompt.id) }
        .alert(
            "Farcast",
            isPresented: Binding(
                get: { workspace.focusedDetachedSlot == nil && workspace.error != nil },
                set: { if !$0 { workspace.error = nil } })
        ) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
        .alert(editingFolder == nil ? "New folder" : "Rename folder", isPresented: $showFolderEditor) {
            TextField("Folder name", text: $folderName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    if let editingFolder {
                        editingFolder.name = name
                    } else {
                        let folder = ConnectionFolder(name: name, order: folders.count)
                        folder.parentID = newFolderParentID
                        context.insert(folder)
                    }
                    save()
                }
            }
        }
        .confirmationDialog(
            "Delete \(deletingConnection?.name ?? "connection")?",
            isPresented: Binding(get: { deletingConnection != nil }, set: { if !$0 { deletingConnection = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Connection", role: .destructive) {
                if let connection = deletingConnection { delete(connection) }
                deletingConnection = nil
            }
            Button("Cancel", role: .cancel) { deletingConnection = nil }
        } message: {
            Text(
                "This removes the saved profile and its saved credentials. Open sessions remain available until you close them."
            )
        }
        .confirmationDialog(
            "Delete \(deletingFolder?.name ?? "folder")?",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = deletingFolder { deleteFolder(folder) }
                deletingFolder = nil
            }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: {
            Text("Connections and subfolders move to the parent folder. Saved connections and credentials are kept.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow { workspace.activate(window) }
        }
        .task {
            workspace.modelContext = context
            workspace.restoreWorkspace(connections)
        }
    }
    private var ungrouped: [SavedConnection] {
        filtered.filter { connection in
            connection.folderID == nil || !folders.contains { $0.id == connection.folderID }
        }
    }
    private var rootFolders: [ConnectionFolder] {
        folders.filter { folder in
            folder.parentID == nil || !folders.contains { $0.id == folder.parentID }
        }
    }
    private func folderPath(_ id: UUID?) -> String {
        var id = id
        var names: [String] = []
        var seen = Set<UUID>()
        while let current = id, seen.insert(current).inserted,
            let folder = folders.first(where: { $0.id == current })
        {
            names.insert(folder.name, at: 0)
            id = folder.parentID
        }
        return names.joined(separator: " / ")
    }
    private func folderIDs(_ folder: ConnectionFolder) -> Set<UUID> {
        var ids: Set<UUID> = [folder.id]
        var previousCount = 0
        while previousCount != ids.count {
            previousCount = ids.count
            for child in folders where child.parentID.map({ ids.contains($0) }) == true { ids.insert(child.id) }
        }
        return ids
    }
    private func folderTree(_ folder: ConnectionFolder, ancestors: Set<UUID>) -> AnyView {
        let ids = folderIDs(folder)
        let matches = filtered.filter { $0.folderID.map { ids.contains($0) } == true }
        let children = folders.filter { $0.parentID == folder.id && !ancestors.contains($0.id) }
        let expanded = Binding(
            get: { !search.isEmpty || folder.isCollapsed != true },
            set: {
                folder.isCollapsed = !$0
                save()
            })
        return AnyView(
            Group {
                if search.isEmpty || !matches.isEmpty {
                    DisclosureGroup(isExpanded: expanded) {
                        ForEach(children) { child in folderTree(child, ancestors: ancestors.union([folder.id])) }
                        ForEach(filtered.filter { $0.folderID == folder.id }) { connectionRow($0) }
                        if matches.isEmpty {
                            Text("No connections").font(.caption).foregroundStyle(.secondary)
                                .anchorPreference(key: SidebarContentBoundsKey.self, value: .bounds) { [$0] }
                        }
                    } label: {
                        SidebarFolderLabel(
                            name: folder.name, count: matches.count, expanded: expanded.wrappedValue,
                            dropConnections: { move($0, to: folder.id) }
                        )
                        .contextMenu {
                            Menu("New Connection in Folder") {
                                ForEach(RemoteProtocol.allCases) { kind in
                                    Button(kind.rawValue) { create(kind, folderID: folder.id) }
                                }
                            }
                            Button("New Subfolder…") {
                                editingFolder = nil
                                newFolderParentID = folder.id
                                folderName = ""
                                showFolderEditor = true
                            }
                            Button("Rename Folder…") {
                                editingFolder = folder
                                folderName = folder.name
                                showFolderEditor = true
                            }
                            Button("Delete Folder…", role: .destructive) { deletingFolder = folder }
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: expanded.wrappedValue)
                }
            })
    }
    @ViewBuilder private var addMenuItems: some View {
        Button("New SSH Connection") { create(.ssh) }
        Button("New RDP Connection") { create(.rdp) }
        Button("New VNC Connection") { create(.vnc) }
        Divider()
        Button("VPN Connections…") { workspace.showWireGuard = true }
        Button("Import from ~/.ssh/config…") { chooseSSHConfig() }
        Button("Import Test Servers…") { workspace.chooseTestServerFile() }
        Button("Import Existing Library…") { workspace.showLibraryImport = true }
            .disabled(!workspace.sessions.isEmpty)
        Divider()
        Button("New Folder…") {
            editingFolder = nil
            newFolderParentID = nil
            folderName = ""
            showFolderEditor = true
        }
    }
    private func connectionRow(_ connection: SavedConnection) -> some View {
        SidebarConnectionRow(
            connection: connection, workspace: workspace,
            tunnel: tunnels.first { $0.id == connection.wireGuardID },
            selected: selectedProfileID == connection.id, selectionEmphasized: sidebarFocused
        )
        .anchorPreference(key: SidebarContentBoundsKey.self, value: .bounds) { [$0] }
        .tag(connection.id).contentShape(Rectangle())
        .accessibilityAction(named: "Connect") { connect(connection) }
        .onTapGesture(count: 2) { connect(connection) }
        .contextMenu {
            Button("Connect") { connect(connection) }
            Button("Get Info") { infoConnection = connection }
            Button("Edit Connection…") { edit(connection) }
            Button("Duplicate Connection") {
                context.insert(connection.duplicate())
                save()
            }
            Divider()
            Button("Delete Connection…", role: .destructive) { deletingConnection = connection }
        }.draggable(connection.id.uuidString)
    }
    private var overview: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Your remote workspace").font(.system(size: 30, weight: .bold))
                            Text("Connect to a shell or desktop. Keep every server within reach.").font(.body)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "network").font(.system(size: 48, weight: .light)).foregroundStyle(
                            .tint.opacity(0.6))
                    }.padding(.top, 18)
                    HStack(spacing: 16) {
                        launchCard(
                            "SSH Terminal", subtitle: "A secure shell, right here.", kind: .ssh,
                            color: .teal
                        ) { create(.ssh) }
                        launchCard(
                            "Remote Desktop", subtitle: "Control your Windows servers.", kind: .rdp,
                            color: .indigo
                        ) { create(.rdp) }
                        launchCard(
                            "VNC Desktop", subtitle: "Control a VNC server.", kind: .vnc,
                            color: .orange
                        ) { create(.vnc) }
                    }
                    if let selected = connections.first(where: { $0.id == selectedProfileID }) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(selected.name, systemImage: selected.kind.icon).font(.headline)
                                Spacer()
                                Button("Edit…") {
                                    edit(selected)
                                }
                                PrimaryActionButton(title: "Connect") { connect(selected) }
                            }
                            Text("\(selected.username)@\(selected.host):\(String(selected.port))").font(
                                .system(.body, design: .monospaced)
                            ).foregroundStyle(.secondary).textSelection(.enabled)
                            if !selected.notes.isEmpty { Text(selected.notes).foregroundStyle(.secondary) }
                        }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 14))
                    }
                    Button("Quick Connect") {
                        workspace.editor = EditorRequest(draft: ConnectionDraft(), mode: .quick)
                    }.buttonStyle(.bordered)
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield")
                        Text("Credentials stay on this Mac. Server identities are checked before sign-in.")
                    }.font(.callout).foregroundStyle(.secondary)
                }.padding(36).frame(maxWidth: 860, alignment: .leading)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
    private func launchCard(
        _ title: String, subtitle: String, kind: RemoteProtocol, color: Color, action: @escaping () -> Void
    )
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    ConnectionProtocolIcon(kind: kind, size: 24)
                    Spacer()
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(
                color.opacity(0.06), in: RoundedRectangle(cornerRadius: 14)
            ).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.15)))
        }.buttonStyle(.plain)
    }
    private func chooseSSHConfig() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an SSH config to review metadata for import. Keys and included files will not be read."
        panel.nameFieldStringValue = "config"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_577) ?? Data()
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
                    throw SSHConfigImport.ImportError.invalid
                }
                sshConfigImport = try SSHConfigImport(text: text)
                showSSHConfigImport = true
            } catch {
                workspace.error =
                    "The selected SSH config could not be imported. Choose a UTF-8 config no larger than 1 MB with valid quoted values."
            }
        }
    }
    private func create(_ kind: RemoteProtocol, folderID: UUID? = nil) {
        var draft = ConnectionDraft()
        draft.kind = kind
        draft.folderID = folderID
        draft.port = kind.defaultPort
        workspace.editor = EditorRequest(draft: draft, mode: .create)
    }
    private func edit(_ connection: SavedConnection) {
        workspace.editor = EditorRequest(draft: ConnectionDraft(connection), mode: .edit)
    }
    private func connect(_ connection: SavedConnection) {
        connection.lastConnected = Date()
        save()
        workspace.connect(ConnectionDraft(connection))
    }
    private func save() { do { try context.save() } catch { workspace.error = error.localizedDescription } }
    private func delete(_ connection: SavedConnection) {
        do {
            try CredentialStore.delete(connection.id)
            context.delete(connection)
            try context.save()
        } catch { workspace.error = error.localizedDescription }
    }
    private func deleteFolder(_ folder: ConnectionFolder) {
        for connection in connections where connection.folderID == folder.id { connection.folderID = folder.parentID }
        for child in folders where child.parentID == folder.id { child.parentID = folder.parentID }
        context.delete(folder)
        save()
    }
    private func move(_ values: [String], to folder: UUID?) -> Bool {
        let ids = values.compactMap(UUID.init(uuidString:))
        let matches = connections.filter { ids.contains($0.id) }
        for connection in matches { connection.folderID = folder }
        save()
        return !matches.isEmpty
    }
}

/// Window identity is independent of the user-visible connection title.
private struct WorkspaceWindowRegistration: NSViewRepresentable {
    let workspace: Workspace
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.workspace = workspace
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) { view.workspace = workspace }
    final class WindowView: NSView {
        weak var workspace: Workspace?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.workspace?.registerMainWindow(window)
            }
        }
    }
}
