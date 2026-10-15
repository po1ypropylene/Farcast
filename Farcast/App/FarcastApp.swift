import AppKit
import SwiftData
import SwiftUI

@main struct FarcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()
    @AppStorage("appearance") private var appearance = "System"
    private let container: ModelContainer?
    private let startupError: String?
    init() {
        if ProcessInfo.processInfo.arguments.contains("--verify-bundle-launch") {
            print("Farcast loader check passed")
            exit(EXIT_SUCCESS)
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-wireguard-helper") {
            exit(WireGuardBundleProbe.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-ssh-listener") {
            let success = FCSSHClient.verifyForwardingListener()
            print(
                success ? "Farcast sandboxed SSH listener check passed" : "Farcast sandboxed SSH listener check failed")
            exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        do {
            container = try ModelContainer(for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self)
            startupError = nil
        } catch {
            container = nil
            startupError = error.localizedDescription
        }
    }
    var body: some Scene {
        Window("Farcast", id: "workspace") {
            Group {
                if let container {
                    WorkspaceView(workspace: workspace).modelContainer(container).onAppear {
                        delegate.workspace = workspace
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                        Text("Connection library could not be opened").font(.title2)
                        Text(startupError ?? "Unknown storage error").textSelection(.enabled)
                        Button("Quit") { NSApp.terminate(nil) }
                    }.padding(40).frame(width: 600)
                }
            }.preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        }.defaultSize(width: 1280, height: 820)
            .commands {
                SidebarCommands()
                CommandGroup(replacing: .newItem) {
                    Button("New Connection…") {
                        workspace.editor = EditorRequest(draft: ConnectionDraft(), mode: .create)
                    }.keyboardShortcut("n")
                    Button("Quick Connect…") {
                        workspace.editor = EditorRequest(draft: ConnectionDraft(), mode: .quick)
                    }.keyboardShortcut("k")
                }
                CommandGroup(replacing: .saveItem) {
                    Button("WireGuard Connections…") { workspace.showWireGuard = true }
                    Button("Import Test Servers…") { workspace.chooseTestServerFile() }
                    Button("Import Existing Library…") { workspace.showLibraryImport = true }
                        .disabled(!workspace.sessions.isEmpty)
                }
                CommandGroup(replacing: .textEditing) {
                    if let session = workspace.activeSession {
                        FindInTerminalCommandButton(session: session)
                    } else {
                        Button("Find in Terminal…") {}.keyboardShortcut("f").disabled(true)
                    }
                }
                CommandMenu("Session") {
                    if let session = workspace.activeSession {
                        SessionMenuItems(session: session, workspace: workspace)
                    } else {
                        Text("No active session")
                    }
                    Divider()
                    Button("Disconnect All") { workspace.requestDisconnectAll() }
                        .keyboardShortcut("d", modifiers: [.command, .option, .shift])
                        .disabled(!workspace.sessions.contains { $0.state.active })
                }
            }
        Settings { AppSettings() }
    }
}

private struct FindInTerminalCommandButton: View {
    @ObservedObject var session: RemoteSession
    var body: some View {
        Button("Find in Terminal…") {
            guard session.terminalAvailable else { return }
            session.terminal?.find()
        }.keyboardShortcut("f").disabled(!session.showsTerminalTools)
    }
}

// Session publishing updates menu availability even when the selected tab stays the same.
private struct SessionMenuItems: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    var body: some View {
        Group {
            Button("Reconnect") {
                workspace.requestReconnect(session)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Disconnect") {
                workspace.requestDisconnect(session)
            }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(
                session.state.active != true)
            Button("Close Session") {
                workspace.requestClose(session)
            }
            .keyboardShortcut("w")
            Divider()
            ForEach(SSHWorkspaceMode.allCases) { mode in
                Button(mode == .split ? "Split View" : mode.rawValue) {
                    session.sshMode = mode
                }
                .keyboardShortcut(
                    mode == .terminal ? "1" : mode == .files ? "2" : mode == .split ? "3" : "4",
                    modifiers: [.command, .option]
                )
                .disabled(
                    session.profile.kind != .ssh || !session.supports(mode)
                )
            }
            Button("Increase Terminal Zoom") { session.zoomTerminal(1) }.keyboardShortcut(
                "+", modifiers: [.command]
            )
            .disabled(!session.showsTerminalTools)
            Button("Decrease Terminal Zoom") { session.zoomTerminal(-1) }.keyboardShortcut(
                "-", modifiers: [.command]
            )
            .disabled(!session.showsTerminalTools)
            Button("Reset Terminal Zoom") { session.resetTerminalZoom() }.keyboardShortcut(
                "0", modifiers: [.command]
            )
            .disabled(!session.showsTerminalTools)
            Divider()
            Button("Send Ctrl+Alt+Delete") { session.controlAltDelete() }.disabled(
                session.profile.kind == .ssh
                    || session.state != .connected)
            Button("Paste Text from Clipboard") { session.pasteTextFromClipboard() }
                .disabled(
                    session.profile.kind != .vnc
                        || session.state != .connected)
            Button("Cancel Typing") { session.cancelVNCTyping() }
                .disabled(session.vncTyping != true)
            Divider()
            Button("Full Screen") { workspace.toggleSessionFullScreen() }
                .keyboardShortcut("f", modifiers: [.command, .control]).disabled(
                    session.profile.kind != .ssh && session.state != .connected)
            Button(workspace.focusedDetachedSlot == nil ? "Pop Out Session" : "Return to Workspace") {
                workspace.popOutActiveSession()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Connection Details") { workspace.toggleInspector() }.keyboardShortcut(
                "i", modifiers: [.command, .option])

        }
    }
}
