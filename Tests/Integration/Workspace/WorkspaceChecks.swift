import AppKit
import Combine
import SwiftData

// Transport doubles keep coordination tests away from networks, Keychain and UI prompts.
@MainActor final class RemoteSession: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ConnectionDraft
    let persistent: Bool
    var state: SessionState = .disconnected
    var message = ""
    var isSelected = false
    var credentialsRejected = false
    var desktop: DesktopDouble? { nil }
    init(profile: ConnectionDraft, workspace: Workspace, persistent: Bool = true) {
        self.profile = profile
        self.persistent = persistent
    }
    func start(credential: ConnectionCredential) { state = .connected }
    func askForCredentials() { state = .authenticating }
    func disconnect() { state = .disconnected }
    func focus() {}
}
@MainActor final class DesktopDouble {
    var window: NSWindow? { nil }
    var desktopSize: CGSize { .zero }
    var retinaDisplay: Bool { false }
    var viewport: ViewportDouble? { nil }
    func releaseInput() {}
    func inheritViewportGeometry(from desktop: DesktopDouble) {}
}
@MainActor final class ViewportDouble {
    var window: NSWindow? { nil }
    let contentView = NSView()
    func layoutDesktop() {}
}
struct TestServerImportRequest {
    let document: TestServerDocument
}

// Delayed completions expose an early termination reply and main-thread blocking.
enum CleanupDouble {
    static var completed = 0
    static func drain(after delay: Double, completion: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            completed += 1
            completion()
        }
    }
}
enum FCSSHClient {
    static func whenAllDisconnected(_ completion: @escaping () -> Void) {
        CleanupDouble.drain(after: 0.05, completion: completion)
    }
}
enum FCRDPClient {
    static func whenAllDisconnected(_ completion: @escaping () -> Void) {
        CleanupDouble.drain(after: 0.1, completion: completion)
    }
}
enum FCVNCClient {
    static func whenAllDisconnected(_ completion: @escaping () -> Void) {
        CleanupDouble.drain(after: 0.12, completion: completion)
    }
}
enum WireGuardTransport {
    static func shutdownAll(completion: @escaping () -> Void) {
        CleanupDouble.drain(after: 0.15, completion: completion)
    }
}

@main struct WorkspaceChecks {
    @MainActor static func main() throws {
        if let mode = CommandLine.arguments.dropFirst().first {
            terminationCheck(mode)
        }
        let suite = "com.peterpo.farcast.WorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var refuseCredentials = false
        let workspace = Workspace(
            loadCredential: { _ in
                if refuseCredentials { throw CocoaError(.fileReadNoPermission) }
                return ConnectionCredential()
            }, defaults: defaults)
        let container = try ModelContainer(
            for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        workspace.modelContext = container.mainContext
        func draft(_ name: String) -> ConnectionDraft {
            var draft = ConnectionDraft()
            draft.name = name
            draft.host = "fixture.invalid"
            draft.username = "fixture"
            return draft
        }
        for name in ["First", "Second", "Third"] { workspace.connect(draft(name)) }
        let first = workspace.sessions[0]
        let second = workspace.sessions[1]
        let third = workspace.sessions[2]
        workspace.reorder(first.id, before: second.id)
        precondition(workspace.sessions.map(\.id) == [first.id, second.id, third.id])
        workspace.reorder(first.id, before: third.id)
        precondition(workspace.sessions.map(\.id) == [second.id, first.id, third.id])
        workspace.reorder(third.id, before: second.id)
        precondition(workspace.sessions.map(\.id) == [third.id, second.id, first.id])
        print("PASS tab reordering in both directions and adjacent drop")

        workspace.select(third.id)
        workspace.reconnect(second)
        let replaced = workspace.sessions[1]
        precondition(replaced.id != second.id && replaced.profile.id == second.profile.id)
        precondition(workspace.selectedSessionID == third.id && second.state == .disconnected)
        print("PASS background reconnect retains position and selected tab")

        var edited = first.profile
        edited.name = "Edited"
        edited.clipboard = true
        let saved = SavedConnection(draft: edited)
        container.mainContext.insert(saved)
        try container.mainContext.save()
        workspace.select(first.id)
        workspace.reconnect(first)
        let selected = workspace.sessions[2]
        precondition(selected.profile.name == "Edited" && selected.profile.clipboard)
        precondition(workspace.selectedSessionID == selected.id && selected.isSelected)
        print("PASS selected reconnect reloads saved edits in place")

        refuseCredentials = true
        workspace.reconnect(selected)
        precondition(workspace.sessions[2] === selected && selected.state == .connected)
        precondition(workspace.selectedSessionID == selected.id && workspace.error != nil)
        refuseCredentials = false
        saved.port = 0
        workspace.reconnect(selected)
        precondition(workspace.sessions[2] === selected && selected.state == .connected)
        saved.port = 22
        print("PASS credential and validation failures preserve existing session")

        workspace.connect(draft("Temporary"), persistent: false)
        let temporary = workspace.sessions.last!
        let restored = defaults.stringArray(forKey: "workspaceConnections")!
        precondition(!restored.contains(temporary.profile.id.uuidString))
        container.mainContext.insert(SavedConnection(draft: temporary.profile))
        workspace.reconnect(temporary)
        precondition(workspace.sessions.last?.persistent == false)
        print("PASS ad hoc reconnect and restoration exclusion")

        let count = workspace.sessions.count
        workspace.close(first)
        workspace.reconnect(first)
        precondition(workspace.sessions.count == count)
        workspace.close(workspace.sessions.last!)
        precondition(workspace.selectedSessionID == selected.id)
        print("PASS stale actions and close selection")

        selected.credentialsRejected = true
        refuseCredentials = true
        workspace.reconnect(selected)
        let retry = workspace.selectedSession!
        precondition(retry.id != selected.id && retry.state == .authenticating)
        precondition(retry.profile.id == selected.profile.id && retry.persistent)
        precondition(workspace.sessions[2] === retry && selected.state == .disconnected)
        print("PASS rejected SSH credentials prompt afresh without reloading saved credentials")

        var interactive = draft("Interactive retry")
        interactive.authentication = .interactive
        workspace.connect(interactive)
        let interactiveSession = workspace.sessions.last!
        interactiveSession.credentialsRejected = true
        workspace.reconnect(interactiveSession)
        precondition(workspace.sessions.last!.state == .connected)
        precondition(workspace.sessions.last!.profile.authentication == .interactive)
        print("PASS interactive retry uses server prompts without saved credential lookup")

        _ = NSApplication.shared
        let detached = workspace.sessions[0]
        let originalCount = workspace.sessions.count
        let detachedContent = NSView()
        workspace.popOut(detached) { _ in detachedContent }
        let slot = workspace.detachedSessions.first!.key
        precondition(workspace.session(in: slot) === detached && detached.state == .connected)
        precondition(workspace.attachedSessions.count == originalCount - 1 && workspace.activeSession === detached)
        workspace.popOut(detached) { _ in preconditionFailure("Existing window must be reused") }
        precondition(workspace.detachedSessions.count == 1 && workspace.sessions.count == originalCount)
        let auxiliaryWindow = NSWindow()
        workspace.activate(auxiliaryWindow)
        precondition(workspace.activeSession === detached)
        workspace.toggleInspector()
        precondition(workspace.detachedInspectors.contains(slot) && !workspace.showInspector)
        workspace.toggleInspector()
        precondition(!workspace.detachedInspectors.contains(slot))
        print("PASS pop out retains session, removes main presentation and reuses window")
        refuseCredentials = false
        workspace.reconnect(detached)
        let detachedReplacement = workspace.session(in: slot)!
        precondition(detachedReplacement !== detached && detached.state == .disconnected)
        precondition(detachedReplacement.state == .connected && workspace.activeSession === detachedReplacement)
        refuseCredentials = true
        workspace.reconnect(detachedReplacement)
        precondition(workspace.session(in: slot) === detachedReplacement && detachedReplacement.state == .connected)
        refuseCredentials = false
        print("PASS detached reconnect preserves window and failure preserves transport")
        workspace.returnToWorkspace(slot: slot)
        precondition(workspace.detachedSessions.isEmpty && workspace.selectedSession === detachedReplacement)
        precondition(detachedReplacement.state == .connected && detachedReplacement.isSelected)
        workspace.popOut(detachedReplacement) { _ in NSView() }
        let other = workspace.attachedSessions.first!
        workspace.popOut(other) { _ in NSView() }
        workspace.close(detachedReplacement)
        precondition(workspace.activeSession === other && other.isSelected)
        precondition(workspace.detachedSessions.count == 1 && detachedReplacement.state == .disconnected)
        workspace.returnToWorkspace(slot: workspace.detachedSessions.first!.key)
        precondition(workspace.detachedSessions.isEmpty && other.state == .connected)
        precondition(!workspace.sessions.contains { $0 === detachedReplacement })
        precondition(workspace.activeSession?.isSelected != false)
        print("PASS window close returns live session; explicit session close disconnects and releases window")

        let remembered = defaults.stringArray(forKey: "workspaceConnections")
        var replies = 0
        workspace.shutdown { replies += 1 }
        workspace.shutdown { replies += 1 }
        workspace.connect(draft("Too late"))
        workspace.reconnect(retry)
        let waiter = PromptWaiter()
        workspace.enqueue(
            SessionPrompt(sessionID: retry.id, kind: .interactive, title: "Late", details: "", waiter: waiter))
        precondition(waiter.wait() == nil && workspace.prompts.isEmpty)
        precondition(replies == 0 && workspace.sessions.allSatisfy { $0.state == .disconnected })
        precondition(defaults.stringArray(forKey: "workspaceConnections") == remembered)
        let deadline = Date().addingTimeInterval(5)
        while replies < 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(replies == 2 && CleanupDouble.completed == 4)
        let delegate = AppDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        precondition(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        print("PASS shutdown drains all transports once, cancels late prompts and retains restoration")
    }

    @MainActor static func terminationCheck(_ mode: String) -> Never {
        precondition(mode == "close-window" || mode == "quit")
        let app = NSApplication.shared
        let suite = "com.peterpo.farcast.TerminationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let workspace = Workspace(loadCredential: { _ in ConnectionCredential() }, defaults: defaults)
        var draft = ConnectionDraft()
        draft.host = "fixture.invalid"
        draft.username = "fixture"
        workspace.connect(draft)
        draft.id = UUID()
        draft.kind = .rdp
        draft.port = 3389
        workspace.connect(draft)
        let delegate = AppDelegate()
        delegate.workspace = workspace
        app.delegate = delegate
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: app, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                precondition(CleanupDouble.completed == 4 && workspace.isShuttingDown)
                precondition(workspace.sessions.allSatisfy { $0.state == .disconnected })
                let testDefaults = UserDefaults(suiteName: suite)!
                testDefaults.removePersistentDomain(forName: suite)
                testDefaults.synchronize()
                let preferenceFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Preferences/\(suite).plist")
                try? FileManager.default.removeItem(at: preferenceFile)
                print("PASS actual AppKit \(mode) exits after SSH/RDP/WireGuard cleanup")
                fflush(stdout)
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let trigger = Timer(timeInterval: 0.02, repeats: false) { _ in
            MainActor.assumeIsolated {
                if mode == "close-window" { window.close() } else { app.terminate(nil) }
            }
        }
        let watchdog = Timer(timeInterval: 5, repeats: false) { _ in
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            fputs("FAIL AppKit termination timed out\n", stderr)
            exit(1)
        }
        RunLoop.main.add(trigger, forMode: .common)
        RunLoop.main.add(watchdog, forMode: .common)
        withExtendedLifetime((delegate, window, observer)) { app.run() }
        exit(1)
    }
}
