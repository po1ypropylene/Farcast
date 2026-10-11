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
                            SSHWorkspacePicker(
                                selection: $session.sshMode, terminalAvailable: session.terminalAvailable
                            )
                            .frame(width: 240, height: 28)
                            if !session.terminalAvailable {
                                Text("File transfer only").font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(8).background(.bar)
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
                        }
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
                                Button("Close") { workspace.close(session) }
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
                Text("·").foregroundStyle(.tertiary)
                Text("\(session.profile.username)@\(session.profile.host):\(String(session.profile.port))").lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                if session.state == .connected, !session.clipboardMessage.isEmpty {
                    Text(session.clipboardMessage).lineLimit(1).truncationMode(.tail)
                        .help(session.clipboardMessage)
                        .accessibilityLabel("File clipboard: \(session.clipboardMessage)")
                }
                if session.profile.kind == .rdp {
                    Button("Ctrl + Alt + Delete") { session.controlAltDelete() }.disabled(session.state != .connected)
                } else {
                    IconActionButton(title: "Decrease terminal font size", symbol: "minus.magnifyingglass") {
                        session.terminal?.zoom(-1)
                    }.disabled(!session.terminalAvailable)
                    IconActionButton(title: "Increase terminal font size", symbol: "plus.magnifyingglass") {
                        session.terminal?.zoom(1)
                    }.disabled(!session.terminalAvailable)
                    IconActionButton(title: "Find in terminal", symbol: "magnifyingglass") {
                        session.terminal?.find()
                    }.disabled(session.state != .connected || !session.terminalAvailable)
                }
                Text(session.profile.kind.rawValue).fontWeight(.semibold)
            }.buttonStyle(.bordered).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14)
                .padding(
                    .vertical, 4
                ).background(.bar)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}

// SwiftUI's macOS segmented Picker ignores disabled state on individual items.
// AppKit retains native keyboard/accessibility behavior and disables each segment.
private struct SSHWorkspacePicker: NSViewRepresentable {
    @Binding var selection: SSHWorkspaceMode
    let terminalAvailable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: SSHWorkspaceMode.allCases.map(\.rawValue), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.selectMode(_:)))
        control.controlSize = .regular
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        control.setAccessibilityLabel("SSH workspace")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, mode) in SSHWorkspaceMode.allCases.enumerated() {
            control.setEnabled(terminalAvailable || mode == .files, forSegment: index)
            control.setWidth(0, forSegment: index)
        }
        let mode = terminalAvailable ? selection : .files
        control.selectedSegment = SSHWorkspaceMode.allCases.firstIndex(of: mode) ?? 0
        control.setAccessibilityHelp(
            terminalAvailable ? "SSH workspace" : "This connection supports file transfer only.")
    }
    @MainActor final class Coordinator: NSObject {
        var parent: SSHWorkspacePicker
        init(_ parent: SSHWorkspacePicker) { self.parent = parent }
        @objc func selectMode(_ control: NSSegmentedControl) {
            guard SSHWorkspaceMode.allCases.indices.contains(control.selectedSegment) else { return }
            let mode = SSHWorkspaceMode.allCases[control.selectedSegment]
            guard parent.terminalAvailable || mode == .files else { return }
            parent.selection = mode
        }
    }
}
