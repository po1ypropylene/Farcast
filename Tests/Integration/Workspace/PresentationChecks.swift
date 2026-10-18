import AppKit
import SwiftData
import SwiftUI

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
        settle()
        try snapshot("vpn-failed", window: window)
        vpnSession.disconnect()
        precondition(vpnSession.vpnState == .disconnected)
        settle()
        try snapshot("vpn-disconnected", window: window)
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
