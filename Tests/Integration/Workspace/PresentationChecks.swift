import AppKit
import SwiftData
import SwiftUI

private final class InspectorRDPClient: FCRDPClient {
    override func connectHost(
        _ host: String, port: Int, username: String, domain: String, password: String,
        width: Int, height: Int, scale: Int, clipboard: Bool, audioPlayback: Bool
    ) {
        onStatus("connected", "Synthetic desktop connected")
        onDesktopSize?(width, height)
    }
}

/// Exercises the production SwiftUI hosts and persistent desktop across real windows.
@main struct PresentationChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let suite = "com.peterpo.farcast.PresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(loadCredential: { _ in ConnectionCredential() }, defaults: defaults)
        let container = try ModelContainer(
            for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        workspace.modelContext = container.mainContext
        var draft = ConnectionDraft()
        draft.name = "Synthetic Desktop"
        draft.host = "fixture.invalid"
        draft.username = "fixture"
        draft.kind = .rdp
        draft.port = 3389
        draft.displayMode = .actualSize
        let saved = SavedConnection(draft: draft)
        container.mainContext.insert(saved)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Farcast"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(.dark))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        func settle() {
            let until = Date().addingTimeInterval(0.35)
            while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func snapshot(_ name: String, window: NSWindow) throws {
            let output =
                CommandLine.arguments.dropFirst().first
                ?? ProcessInfo.processInfo.environment["FARCAST_PRESENTATION_SNAPSHOTS"]
            if let output, ProcessInfo.processInfo.environment["FARCAST_PRESENTATION_REVIEW"] == name {
                let marker = URL(fileURLWithPath: output).appendingPathComponent("continue")
                print("REVIEW synthetic session status: \(name)")
                fflush(stdout)
                let deadline = Date().addingTimeInterval(45)
                while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                try? FileManager.default.removeItem(at: marker)
            }
            guard let output, let view = window.contentView,
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
        settle()
        try snapshot("home", window: window)
        for theme in ["Midnight", "Solarized", "Paper"] {
            for size in [13.0, 24.0] {
                var previewDraft = ConnectionDraft()
                previewDraft.terminalTheme = theme
                previewDraft.fontSize = size
                window.contentView = NSHostingView(
                    rootView: ConnectionEditor(
                        workspace: workspace,
                        request: EditorRequest(draft: previewDraft, mode: .create, initialTab: .terminal),
                        loadCredential: { _ in nil }
                    ).modelContainer(container))
                settle()
                try snapshot("terminal-preview-\(theme)-\(Int(size))", window: window)
            }
        }
        print("PASS native SSH appearance editor renders all themes at normal and enlarged font sizes")
        // Review every protocol with native selected/unselected rows and compact tabs.
        let iconWorkspace = Workspace(loadCredential: { _ in ConnectionCredential() }, defaults: defaults)
        let iconProfiles = RemoteProtocol.allCases.map { kind in
            var profile = ConnectionDraft()
            profile.name = "Synthetic \(kind.rawValue)"
            profile.kind = kind
            profile.host = "fixture.invalid"
            return SavedConnection(draft: profile)
        }
        iconWorkspace.sessions = iconProfiles.map {
            RemoteSession(profile: ConnectionDraft($0), workspace: iconWorkspace, persistent: false)
        }
        iconWorkspace.select(iconWorkspace.sessions[0].id)
        for scheme in [ColorScheme.light, .dark] {
            for contrast in [false, true] {
                window.appearance = NSAppearance(
                    named: contrast
                        ? (scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
                        : (scheme == .light ? .aqua : .darkAqua))
                window.contentView = NSHostingView(
                    rootView:
                        VStack(alignment: .leading) {
                            HStack {
                                ForEach(iconWorkspace.sessions) { session in
                                    SessionTab(session: session, workspace: iconWorkspace)
                                }
                            }
                            HStack {
                                ForEach([false, true], id: \.self) { selected in
                                    List(selection: .constant(selected ? Set(iconProfiles.map(\.id)) : Set<UUID>())) {
                                        ForEach(iconProfiles) { profile in
                                            SidebarConnectionRow(
                                                connection: profile, workspace: iconWorkspace,
                                                tunnel: nil, selected: selected,
                                                selectionEmphasized: selected
                                            ).tag(profile.id)
                                        }
                                    }.listStyle(.sidebar)
                                }
                            }
                        }.padding().frame(width: 1000, height: 360)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.controlActiveState, .key)
                        .preferredColorScheme(scheme)
                )
                settle()
                func focusSelectedList(_ view: NSView) {
                    if let table = view as? NSTableView { window.makeFirstResponder(table) }
                    for child in view.subviews { focusSelectedList(child) }
                }
                if let view = window.contentView { focusSelectedList(view) }
                settle()
                try snapshot("protocol-icons-\(scheme)-\(contrast ? "contrast" : "standard")", window: window)
            }
        }
        window.appearance = nil
        window.contentView = NSHostingView(
            rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(.dark))
        // Owned profiles exercise hierarchy without importing a user's library.
        let sidebarFolder = ConnectionFolder(name: "Research")
        let sidebarChild = ConnectionFolder(name: "Archives")
        let emptyFolder = ConnectionFolder(name: "Empty destination")
        sidebarChild.parentID = sidebarFolder.id
        container.mainContext.insert(sidebarFolder)
        container.mainContext.insert(sidebarChild)
        container.mainContext.insert(emptyFolder)
        let sidebarVPN = try SavedWireGuard(name: "Lab VPN", configuration: WireGuardConfiguration())
        container.mainContext.insert(sidebarVPN)
        saved.wireGuardID = sidebarVPN.id
        saved.folderID = sidebarFolder.id
        // Legacy favourite metadata must not add duplicate rows or star controls.
        saved.favorite = true
        var sidebarDraft = ConnectionDraft()
        sidebarDraft.name = "Synthetic VNC"
        sidebarDraft.kind = .vnc
        sidebarDraft.host = "desktop.example"
        sidebarDraft.wireGuardID = UUID()
        sidebarDraft.folderID = sidebarChild.id
        let sidebarProfile = SavedConnection(draft: sidebarDraft)
        container.mainContext.insert(sidebarProfile)
        try container.mainContext.save()
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: WorkspaceView(workspace: workspace).modelContainer(container)
                    .preferredColorScheme(scheme))
            settle()
            try snapshot("sidebar-\(scheme)", window: window)
            sidebarFolder.isCollapsed = true
            settle()
            try snapshot("sidebar-collapsed-\(scheme)", window: window)
            sidebarFolder.isCollapsed = false
            window.appearance = NSAppearance(
                named: scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            window.contentView = NSHostingView(
                rootView: WorkspaceView(workspace: workspace).modelContainer(container))
            settle()
            try snapshot("sidebar-contrast-\(scheme)", window: window)
            window.appearance = nil
        }
        let configPreview = try SSHConfigImport(
            text: "Host research\n HostName research.example\n User scientist\n Port 2222")
        window.contentView = NSHostingView(
            rootView: SSHConfigImportView(document: configPreview, reportError: { _ in })
                .modelContainer(container).preferredColorScheme(.light))
        settle()
        try snapshot("sidebar-ssh-import", window: window)
        saved.folderID = nil
        saved.favorite = false
        saved.wireGuardID = nil
        container.mainContext.delete(sidebarVPN)
        container.mainContext.delete(sidebarProfile)
        container.mainContext.delete(sidebarChild)
        container.mainContext.delete(emptyFolder)
        container.mainContext.delete(sidebarFolder)
        try container.mainContext.save()
        window.contentView = NSHostingView(
            rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(.dark))
        settle()
        defaults.set([saved.id.uuidString], forKey: "workspaceConnections")
        workspace.restoreWorkspace([saved])
        let session = workspace.selectedSession!
        precondition(session.vpnState == .disconnected, "Restored sessions must not show a VPN waiting to start")
        // Never start a transport or read clipboard/credentials.
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(scheme))
            for state in [
                SessionState.waiting, .connecting, .verifying, .authenticating, .connected, .stale,
                .reconnecting, .failed, .disconnected,
            ] {
                session.state = state
                settle()
                try snapshot("status-\(scheme)-\(state.rawValue)", window: window)
            }
        }
        let vpn = try SavedWireGuard(name: "Synthetic VPN", configuration: WireGuardConfiguration())
        // Invalid synthetic metadata fails before credential lookup or helper/network startup.
        vpn.configurationData = Data()
        container.mainContext.insert(vpn)
        var vpnDraft = draft
        vpnDraft.id = UUID()
        vpnDraft.name = "Synthetic VPN session"
        vpnDraft.wireGuardID = vpn.id
        let vpnSession = RemoteSession(profile: vpnDraft, workspace: workspace, persistent: false)
        workspace.sessions.append(vpnSession)
        workspace.select(vpnSession.id)
        settle()
        try snapshot("vpn-waiting", window: window)
        vpnSession.start(credential: ConnectionCredential())
        precondition(vpnSession.vpnState == .failed)
        precondition(vpnSession.latestFailure == vpnSession.message && !vpnSession.latestFailure.isEmpty)
        precondition(vpnSession.logs.contains { $0.message.contains("VPN: establishing") })
        workspace.showInspector = true
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(scheme))
            settle()
            try snapshot("details-failure-\(scheme)", window: window)
        }
        settle()
        try snapshot("vpn-failed", window: window)
        vpnSession.disconnect()
        precondition(vpnSession.vpnState == .disconnected)
        precondition(!vpnSession.latestFailure.isEmpty)
        precondition(vpnSession.logs.contains { $0.message.contains("VPN: session transport released") })
        settle()
        try snapshot("vpn-disconnected", window: window)
        var detailsDraft = draft
        detailsDraft.clipboard = false
        detailsDraft.dynamicResolution = false
        let detailsSession = RemoteSession(
            profile: detailsDraft, workspace: workspace, persistent: false,
            makeRDPClient: { InspectorRDPClient() })
        workspace.sessions.append(detailsSession)
        workspace.select(detailsSession.id)
        detailsSession.start(credential: ConnectionCredential())
        settle()
        precondition(!detailsSession.initialResolution.isEmpty && detailsSession.observedDesktopSize != nil)
        for scheme in [ColorScheme.light, .dark] {
            window.contentView = NSHostingView(
                rootView: WorkspaceView(workspace: workspace).modelContainer(container).preferredColorScheme(scheme))
            settle()
            try snapshot("details-desktop-\(scheme)", window: window)
        }
        workspace.close(detailsSession)
        workspace.showInspector = false
        workspace.close(vpnSession)
        workspace.select(session.id)
        session.state = .connected
        let desktop = session.desktop!
        desktop.setDesktopSize(CGSize(width: 1920, height: 1080))
        desktop.mailbox.put(
            DesktopFrame(
                pixels: Data(repeating: 96, count: 1920 * 1080 * 4), width: 1920, height: 1080, stride: 1920 * 4))
        settle()
        precondition(desktop.window === window)
        func checkDetailsLayout(slot: UUID? = nil, host: NSWindow) throws {
            let viewport = desktop.viewport!
            let original = viewport.bounds.size
            func present(_ shown: Bool) {
                if let slot {
                    if workspace.detachedInspectors.contains(slot) != shown { workspace.toggleInspector(slot: slot) }
                } else {
                    workspace.showInspector = shown
                }
                settle()
                host.contentView?.layoutSubtreeIfNeeded()
                settle()
            }
            precondition(!workspace.inspectorPinned)
            present(true)
            precondition(
                desktop.viewport === viewport && viewport.bounds.size == original,
                "Overlay details must preserve the live viewport")
            try snapshot(slot == nil ? "details-overlay" : "detached-details-overlay", window: host)
            workspace.inspectorPinned = true
            settle()
            precondition(
                desktop.viewport === viewport && abs(viewport.bounds.width - (original.width - 301)) < 1,
                "Pinned details must reserve space in the existing viewport")
            precondition(
                Workspace(loadCredential: { _ in nil }, defaults: defaults).inspectorPinned,
                "Pin preference must survive workspace recreation")
            try snapshot(slot == nil ? "details-pinned" : "detached-details-pinned", window: host)
            present(false)
            precondition(viewport.bounds.size == original, "Closing pinned details must restore the work area")
            present(true)
            precondition(
                abs(viewport.bounds.width - (original.width - 301)) < 1,
                "Reopening pinned details must reserve space")
            workspace.inspectorPinned = false
            settle()
            precondition(viewport.bounds.size == original, "Unpinning must restore the work area")
            present(false)
            precondition(viewport.bounds.size == original && desktop.viewport === viewport)
        }
        try checkDetailsLayout(host: window)
        let oldViewport = desktop.viewport!
        workspace.popOut(session) { slot in
            NSHostingView(
                rootView: DetachedSessionView(workspace: workspace, slot: slot).modelContainer(container)
                    .defaultAppStorage(defaults))
        }
        settle()
        let slot = workspace.detachedSessions.first!.key
        let detachedWindow = desktop.window!
        precondition(detachedWindow !== window && workspace.session(in: slot) === session)
        precondition(desktop.viewport !== oldViewport && workspace.attachedSessions.isEmpty)
        detachedWindow.setContentSize(NSSize(width: 1500, height: 950))
        detachedWindow.contentView?.layoutSubtreeIfNeeded()
        let movedSize = desktop.frame.size
        oldViewport.layoutDesktop()
        precondition(desktop.frame.size == movedSize)
        workspace.activate(window)
        precondition(!session.isSelected)
        workspace.activate(detachedWindow)
        precondition(session.isSelected && workspace.activeSession === session)
        try checkDetailsLayout(slot: slot, host: detachedWindow)
        try snapshot("detached", window: detachedWindow)
        print("PASS production desktop moves to one detached viewport and ignores stale layout")
        workspace.returnToWorkspace(slot: slot)
        settle()
        precondition(desktop.window === window && workspace.selectedSession === session)
        precondition(workspace.detachedSessions.isEmpty && session.state == .connected)
        try snapshot("returned", window: window)
        print("PASS production desktop returns live; focus selects one clipboard/input owner")
        workspace.close(session)
        settle()
        // A separate owned empty directory keeps preview enumeration away from personal files.
        let localRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let files = SFTPController(homeURL: localRoot, requiresAccess: false)
        defaults.set(true, forKey: "sftpDiskAccessExplained")
        window.contentView = NSHostingView(
            rootView:
                SFTPView(controller: files, connected: false).defaultAppStorage(defaults).preferredColorScheme(.dark))
        settle()
        try snapshot("sftp", window: window)
        defaults.set(false, forKey: "sftpDiskAccessExplained")
        window.contentView = NSHostingView(
            rootView:
                SFTPView(controller: files, connected: false).defaultAppStorage(defaults).preferredColorScheme(.dark))
        settle()
        precondition(window.attachedSheet != nil)
        try snapshot("file-access", window: window.attachedSheet!)
        print("PASS first-use file-access setup appears with isolated preferences and local files")
        window.endSheet(window.attachedSheet!)
        settle()
        window.close()
    }
}
