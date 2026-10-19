import AppKit
import SwiftTerm
import SwiftUI

struct SessionPane: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    private func terminalView(_ terminal: TerminalController) -> some View {
        // The sidebar is outside the detail safe area; keep the terminal colour inside it.
        TerminalSurface(controller: terminal).padding(8).background(
            SwiftUI.Color(nsColor: terminal.view.nativeBackgroundColor), ignoresSafeAreaEdges: [])
    }
    private var filesView: some View {
        SFTPView(controller: session.files, connected: session.state == .connected)
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let terminal = session.terminal {
                    VStack(spacing: 0) {
                        HStack {
                            HStack(spacing: 20) {
                                ForEach(SSHWorkspaceMode.allCases) { mode in
                                    UnderlineTabButton(
                                        title: mode == .split ? "Split View" : mode.rawValue,
                                        selected: session.sshMode == mode, enabled: session.supports(mode),
                                        help: mode == .split ? "Terminal above files in one session" : mode.rawValue
                                    ) {
                                        session.sshMode = mode
                                    }
                                }
                            }
                            if !session.terminalAvailable {
                                Text(session.filesAvailable ? "File transfer only" : "Tunnels only").font(.callout)
                                    .foregroundStyle(.secondary)
                            } else if !session.filesAvailable {
                                Text("Files unavailable").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(.horizontal, ConnectionFormLayout.inset).background(.bar)
                        switch session.sshMode {
                        case .terminal:
                            terminalView(terminal)
                        case .files:
                            filesView
                        case .split:
                            VSplitView {
                                terminalView(terminal).frame(minHeight: 160)
                                filesView.frame(minHeight: 240)
                            }
                        case .tunnels:
                            SSHForwardingView(
                                controller: session.forwarding, connected: session.state == .connected,
                                profileID: session.persistent ? session.profile.id : nil, server: session.profile.host
                            ) {
                                workspace.editSavedTunnels(for: session.profile)
                            }
                        }
                    }
                } else if session.fullScreenPresented {
                    VStack(spacing: 12) {
                        Image(systemName: "display.2").font(.largeTitle).foregroundStyle(.secondary)
                        Text("The remote desktop is in full screen.")
                        Button("Exit Full Screen") { session.exitFullScreen() }
                    }
                } else if let desktop = session.desktop {
                    DesktopSurface(view: desktop)
                }
                if session.state != .connected {
                    VStack(spacing: 16) {
                        if session.state.active {
                            ProgressView().controlSize(.regular)
                        } else {
                            Image(systemName: session.state == .failed ? "exclamationmark.triangle" : "network").font(
                                .system(size: 36)
                            ).foregroundStyle(session.state.color)
                        }
                        Text(session.state.title).font(.title2.weight(.semibold))
                        Text(session.message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(
                            maxWidth: 460
                        ).textSelection(.enabled)
                        if session.state.active {
                            Button("Cancel connection") { session.disconnect() }
                        } else {
                            HStack {
                                Button("Close") { workspace.requestClose(session) }
                                Button("Connection Details") { workspace.toggleInspector() }
                                PrimaryActionButton(title: session.credentialsRejected ? "Retry sign-in" : "Reconnect")
                                {
                                    workspace.reconnect(session)
                                }
                            }
                        }
                    }.padding(32).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24)).padding(32)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 9) {
                Circle().fill(session.state.color).frame(width: 6, height: 6)
                Text(session.state.title)
                if session.state == .connected, let since = session.connectedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(SessionUptime.string(since: since, now: timeline.date)).monospacedDigit()
                    }.help("Time since connection").accessibilityLabel("Connected since \(since.formatted())")
                }
                Text("·").foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.profile.host, forType: .string)
                } label: {
                    Text(
                        "\(session.profile.username.isEmpty ? "" : session.profile.username + "@")\(session.profile.host):\(String(session.profile.port))"
                    ).lineLimit(1)
                }.buttonStyle(.plain).help("Copy host address")
                    .accessibilityLabel("Copy host address: \(session.profile.host)")
                if session.profile.wireGuardID != nil {
                    Text("·").foregroundStyle(.secondary)
                    Button {
                        workspace.showInspector = true
                    } label: {
                        SessionVPNStatus(session: session)
                    }.buttonStyle(.plain).help("Show tunnel connection details")
                }
                Spacer()
                if session.state == .connected, !session.clipboardMessage.isEmpty {
                    Text(session.clipboardMessage).lineLimit(1).truncationMode(.tail)
                        .help(session.clipboardMessage)
                        .accessibilityLabel("File clipboard: \(session.clipboardMessage)")
                }
                if session.profile.kind != .ssh {
                    if !session.displayMessage.isEmpty {
                        Text(session.displayMessage).lineLimit(1).help(session.displayMessage)
                            .accessibilityLabel("Display: \(session.displayMessage)")
                    }
                    if session.profile.kind == .vnc {
                        if session.vncTyping {
                            Button("Cancel Typing") { session.cancelVNCTyping() }
                        } else {
                            Button("Paste Text from Clipboard") { session.pasteTextFromClipboard() }
                                .help(
                                    "Types clipboard text into the focused remote application, including tabs and newlines."
                                )
                                .disabled(session.state != .connected)
                        }
                    }
                    Button("Ctrl + Alt + Delete") { session.controlAltDelete() }.disabled(session.state != .connected)
                } else if session.showsTerminalTools {
                    IconActionButton(title: "Decrease terminal font size (⌘−)", symbol: "minus") {
                        session.zoomTerminal(-1)
                    }.disabled(!session.terminalAvailable)
                    Button("\(session.terminalZoom)%") { session.resetTerminalZoom() }
                        .monospacedDigit().help("Reset terminal zoom (⌘0)")
                        .accessibilityLabel("Terminal zoom \(session.terminalZoom) percent; reset zoom")
                        .disabled(!session.terminalAvailable)
                    IconActionButton(title: "Increase terminal font size (⌘+)", symbol: "plus") {
                        session.zoomTerminal(1)
                    }.disabled(!session.terminalAvailable)
                    Button {
                        session.terminal?.find()
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }.help("Find in terminal (⌘F)")
                        .accessibilityLabel("Find in terminal")
                        .disabled(session.state != .connected || !session.terminalAvailable)

                }

            }.buttonStyle(.bordered).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14)
                .padding(
                    .vertical, 4
                ).background(.bar)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}
