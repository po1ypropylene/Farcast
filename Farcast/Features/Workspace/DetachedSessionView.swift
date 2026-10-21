import AppKit
import SwiftData
import SwiftUI

/// One presentation owner for the existing transport and native surface.
struct DetachedSessionView: View {
    @Environment(\.modelContext) private var context
    @ObservedObject var workspace: Workspace
    let slot: UUID
    @AppStorage("appearance") private var appearance = "System"

    var body: some View {
        Group {
            if let session = workspace.session(in: slot) {
                VStack(spacing: 0) {
                    DetachedSessionToolbar(session: session, workspace: workspace, slot: slot)
                    Divider()
                    SessionDetailsLayout(
                        session: session, workspace: workspace,
                        isPresented: Binding(
                            get: { workspace.detachedInspectors.contains(slot) },
                            set: { shown in
                                if shown != workspace.detachedInspectors.contains(slot) {
                                    workspace.toggleInspector(slot: slot)
                                }
                            }))
                }
            }
        }
        .modifier(SessionActionConfirmation(workspace: workspace, slot: slot))
        .environment(\.modelContext, workspace.modelContext ?? context)
        .buttonStyle(.bordered).controlSize(.regular)
        .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
        .sheet(
            item: Binding(
                get: { workspace.focusedDetachedSlot == slot ? workspace.editor : nil },
                set: { if workspace.focusedDetachedSlot == slot { workspace.editor = $0 } })
        ) { request in
            ConnectionEditor(workspace: workspace, request: request)
        }
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

private struct DetachedSessionToolbar: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    let slot: UUID
    var body: some View {
        HStack(spacing: 8) {
            Text(session.profile.name).font(.headline).lineLimit(1)
            Spacer()
            IconActionButton(title: "Reconnect (⇧⌘R)", symbol: "arrow.clockwise") {
                workspace.requestReconnect(session)
            }.sessionActionColor(.reconnect)
            SessionDisconnectButton(session: session, workspace: workspace, compact: true)
            Divider().frame(height: 16).padding(.horizontal, 4)
            if session.profile.kind != .ssh {
                SessionFullScreenButton(session: session)
            } else {
                IconActionButton(title: "Full Screen (⌃⌘F)", symbol: "arrow.up.left.and.arrow.down.right") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }.sessionActionColor(.fullScreen)
            }
            IconActionButton(title: "Connection Details (⌥⌘I)", symbol: "sidebar.right") {
                workspace.toggleInspector(slot: slot)
            }.sessionActionColor(.details)
            IconActionButton(title: "Return to Workspace (⇧⌘O)", symbol: "macwindow") {
                workspace.returnToWorkspace(slot: slot)
            }.sessionActionColor(.popOut)
        }.padding(.horizontal, 12).padding(.vertical, 4).background(.bar)
    }
}
