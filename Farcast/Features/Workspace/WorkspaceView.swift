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
    @State private var folderName = ""
    @State private var showFolderEditor = false
    @State private var editingFolder: ConnectionFolder?
    @State private var deletingConnection: SavedConnection?
    private var filtered: [SavedConnection] {
        connections.filter {
            search.isEmpty
                || "\($0.name) \($0.host) \($0.username) \($0.protocolName) \($0.notes)"
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
                    if !filtered.filter(\.favorite).isEmpty {
                        Section {
                            ForEach(filtered.filter(\.favorite)) { connectionRow($0) }
                        } header: {
                            Text("Favorites").foregroundStyle(.primary)
                        }
                    }
                    ForEach(folders) { folder in
                        Section {
                            ForEach(filtered.filter { $0.folderID == folder.id }) { connectionRow($0) }
                            if filtered.filter({ $0.folderID == folder.id }).isEmpty {
                                Text(search.isEmpty ? "No connections" : "No matches").font(.callout).foregroundStyle(
                                    .tertiary)
                            }
                        } header: {
                            Label(folder.name, systemImage: "folder").foregroundStyle(.primary).contextMenu {
                                Button("Rename Folder…") {
                                    editingFolder = folder
                                    folderName = folder.name
                                    showFolderEditor = true
                                }
                                Button("Delete Folder", role: .destructive) { deleteFolder(folder) }
                            }
                        }.dropDestination(for: String.self) { values, _ in return move(values, to: folder.id) }
                    }
                    Section {
                        ForEach(
                            filtered.filter { connection in
                                connection.folderID == nil || !folders.contains(where: { $0.id == connection.folderID })
                            }
                        ) { connectionRow($0) }
                    } header: {
                        Text("Connections").foregroundStyle(.primary)
                    }
                    .dropDestination(for: String.self) { values, _ in return move(values, to: nil) }
                }.listStyle(.sidebar)
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
                        Button("New SSH Connection") { create(.ssh) }
                        Button("New RDP Connection") { create(.rdp) }
                        Button("New VNC Connection") { create(.vnc) }
                        Divider()
                        Button("WireGuard Connections…") { workspace.showWireGuard = true }
                        Button("Import Test Servers…") { workspace.chooseTestServerFile() }
                        Button("Import Existing Library…") { workspace.showLibraryImport = true }
                            .disabled(!workspace.sessions.isEmpty)
                        Divider()
                        Button("New Folder…") {
                            editingFolder = nil
                            folderName = ""
                            showFolderEditor = true
                        }
                    } label: {
                        Label("Add", systemImage: "plus").frame(minWidth: 70, minHeight: 24).contentShape(Rectangle())
                    }.menuStyle(.borderlessButton).controlSize(.regular).frame(minWidth: 70, minHeight: 24)
                    Spacer()
                    Text("\(connections.count) connections").font(.callout).foregroundStyle(.secondary)
                }.padding(14)
            }.navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
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
                    HStack(spacing: 0) {
                        SessionPane(session: session, workspace: workspace).id(session.id)
                        if workspace.showInspector {
                            Divider()
                            SessionInspector(session: session).frame(width: 300)
                        }
                    }
                } else {
                    overview
                }
            }.background(Color(nsColor: .windowBackgroundColor))
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            workspace.editor = EditorRequest(draft: ConnectionDraft(), mode: .quick)
                        } label: {
                            Label("Quick Connect", systemImage: "bolt.fill").labelStyle(.titleAndIcon)
                        }.help("Quick Connect (⌘K)").accessibilityLabel("Quick Connect")
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let session = workspace.selectedSession {
                            Button {
                                workspace.requestReconnect(session)
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
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
                                        .iconOnly)
                                }.help("Full Screen (⌃⌘F)").accessibilityLabel("Full Screen")
                            }
                            Button {
                                workspace.showInspector.toggle()
                            } label: {
                                Label("Connection Details", systemImage: "sidebar.right").labelStyle(.iconOnly)
                            }.help("Connection Details (⌥⌘I)").accessibilityLabel("Connection Details")
                            Button {
                                workspace.popOut(session) { slot in
                                    NSHostingView(rootView: DetachedSessionView(workspace: workspace, slot: slot))
                                }
                            } label: {
                                Label("Pop Out Session", systemImage: "macwindow.on.rectangle").labelStyle(
                                    .iconOnly)
                            }.help("Pop Out Session (⇧⌘O)").accessibilityLabel("Pop Out Session")
                        }
                    }
                }
        }
        .background(WorkspaceWindowRegistration(workspace: workspace))
        .modifier(SessionActionConfirmation(workspace: workspace))
        .buttonStyle(.automatic)
        .navigationTitle(workspace.selectedSession?.profile.name ?? "Workspace")
        .frame(minWidth: 900, minHeight: 660)
        .sheet(item: $workspace.testServerImport) { request in
            TestServerImportView(workspace: workspace, document: request.document)
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
                        context.insert(ConnectionFolder(name: name, order: folders.count))
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow { workspace.activate(window) }
        }
        .task {
            workspace.modelContext = context
            workspace.restoreWorkspace(connections)
        }
    }
    private func connectionRow(_ connection: SavedConnection) -> some View {
        HStack(spacing: 10) {
            Image(systemName: connection.kind.icon).foregroundStyle(connection.kind == .ssh ? Color.teal : Color.indigo)
                .frame(width: 22).help(connection.kind.rawValue).accessibilityLabel(connection.kind.rawValue)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.body).lineLimit(1)
                Text(destinationDescription(connection)).font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(destinationDescription(connection))
            }
            Spacer()
            SidebarSessionState(workspace: workspace, profileID: connection.id)
        }.frame(minHeight: 24).padding(.vertical, 2).tag(connection.id).contentShape(Rectangle())
            .accessibilityAction(named: "Connect") { connect(connection) }
            .onTapGesture(count: 2) { connect(connection) }
            .contextMenu {
                Button("Connect") { connect(connection) }
                Button("Edit Connection…") {
                    edit(connection)
                }
                Button(connection.favorite ? "Remove from Favorites" : "Add to Favorites") {
                    connection.favorite.toggle()
                    save()
                }
                Button("Duplicate Connection") {
                    context.insert(connection.duplicate())
                    save()
                }
                Divider()
                Button("Delete Connection…", role: .destructive) { deletingConnection = connection }
            }.draggable(connection.id.uuidString)
    }
    private func destinationDescription(_ connection: SavedConnection) -> String {
        let destination = connection.username.isEmpty ? connection.host : "\(connection.username)@\(connection.host)"
        guard let tunnelID = connection.wireGuardID else { return destination }
        let name = tunnels.first(where: { $0.id == tunnelID })?.name ?? "Unavailable WireGuard connection"
        return "\(destination) via \(name)"
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
                            "SSH Terminal", subtitle: "A secure shell, right here.", icon: "terminal", color: .teal
                        ) { create(.ssh) }
                        launchCard(
                            "Remote Desktop", subtitle: "Control your Windows servers.", icon: "desktopcomputer",
                            color: .indigo
                        ) { create(.rdp) }
                        launchCard(
                            "VNC Desktop", subtitle: "Control a VNC server.", icon: "display", color: .orange
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
    private func launchCard(_ title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: icon).font(.title).foregroundStyle(color)
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
    private func create(_ kind: RemoteProtocol) {
        var draft = ConnectionDraft()
        draft.kind = kind
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
        for connection in connections where connection.folderID == folder.id { connection.folderID = nil }
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
