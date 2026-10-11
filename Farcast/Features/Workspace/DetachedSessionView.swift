import AppKit
import SwiftUI

/// One presentation owner for the existing transport and native surface.
struct DetachedSessionView: View {
    @ObservedObject var workspace: Workspace
    let slot: UUID
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        Group {
            if let session = workspace.session(in: slot) {
                VStack(spacing: 0) {
                    HStack {
                        Text(session.profile.name).font(.headline).lineLimit(1)
                        Spacer()
                        IconActionButton(title: "Return to Workspace", symbol: "rectangle.portrait.and.arrow.forward") {
                            workspace.returnToWorkspace(slot: slot)
                        }
                        IconActionButton(title: "Reconnect this session", symbol: "arrow.clockwise") {
                            workspace.reconnect(session)
                        }
                        IconActionButton(title: "Disconnect this session", symbol: "stop.circle") {
                            session.disconnect()
                        }.disabled(!session.state.active)
                        if session.profile.kind == .rdp {
                            SessionFullScreenButton(session: session)
                        } else {
                            IconActionButton(title: "Toggle full screen", symbol: "arrow.up.left.and.arrow.down.right")
                            {
                                NSApp.keyWindow?.toggleFullScreen(nil)
                            }
                        }
                        IconActionButton(title: "Show connection details", symbol: "sidebar.right") {
                            workspace.toggleInspector(slot: slot)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
                    Divider()
                    HStack(spacing: 0) {
                        SessionPane(session: session, workspace: workspace).id(session.id)
                        if workspace.detachedInspectors.contains(slot) {
                            Divider()
                            SessionInspector(session: session).frame(width: 300)
                        }
                    }
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        .sheet(
            item: Binding(
                get: { workspace.prompts.first { $0.sessionID == workspace.detachedSessions[slot] } },
                set: { next in
                    if next == nil,
                        let prompt = workspace.prompts.first(where: {
                            $0.sessionID == workspace.detachedSessions[slot]
                        })
                    {
                        workspace.answer(prompt, value: nil)
                    }
                }
            )
        ) { prompt in PromptSheet(workspace: workspace, prompt: prompt).id(prompt.id) }
        .alert(
            "Farcast",
            isPresented: Binding(
                get: { workspace.focusedDetachedSlot == slot && workspace.error != nil },
                set: { if !$0 { workspace.error = nil } }
            )
        ) {
            Button("OK") { workspace.error = nil }
        } message: {
            Text(workspace.error ?? "")
        }
    }
}
