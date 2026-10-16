import SwiftUI

struct SessionActionConfirmation: ViewModifier {
    @ObservedObject var workspace: Workspace
    var slot: UUID?
    private var presents: Bool { workspace.focusedDetachedSlot == slot && workspace.pendingSessionAction != nil }
    func body(content: Content) -> some View {
        content.confirmationDialog(
            workspace.pendingSessionAction?.title ?? "End session?",
            isPresented: Binding(
                get: { presents }, set: { if !$0 && presents { workspace.pendingSessionAction = nil } }),
            titleVisibility: .visible
        ) {
            Button(workspace.pendingSessionAction?.title ?? "Continue", role: .destructive) {
                let action = workspace.pendingSessionAction?.action
                workspace.pendingSessionAction = nil
                action?()
            }
            Button("Cancel", role: .cancel) { workspace.pendingSessionAction = nil }
        } message: {
            Text(workspace.pendingSessionAction?.reason ?? "")
        }
    }
}

extension Workspace {
    func requestDisconnect(_ session: RemoteSession) {
        confirmSessionAction("Disconnect", reason: session.interruptionReason) { session.disconnect() }
    }
    func requestDisconnectAll() {
        let active = sessions.filter { $0.state.active }
        let reasons = Array(Set(active.compactMap(\.interruptionReason))).sorted()
        confirmSessionAction("Disconnect All", reason: reasons.isEmpty ? nil : reasons.joined(separator: " ")) {
            for session in active { session.disconnect() }
        }
    }
    func requestReconnect(_ session: RemoteSession) {
        confirmSessionAction("Reconnect", reason: session.interruptionReason) { self.reconnect(session) }
    }
    func requestClose(_ session: RemoteSession) {
        confirmSessionAction("Close Session", reason: session.interruptionReason) { self.close(session) }
    }
    func toggleSessionFullScreen() {
        guard let session = activeSession else { return }
        if session.profile.kind == .ssh {
            NSApp.keyWindow?.toggleFullScreen(nil)
        } else if session.fullScreenPresented {
            session.exitFullScreen()
        } else {
            session.enterFullScreen()
        }
    }
    func popOutActiveSession() {
        guard let session = activeSession else { return }
        if let slot = focusedDetachedSlot {
            returnToWorkspace(slot: slot)
        } else {
            popOut(session) { slot in NSHostingView(rootView: DetachedSessionView(workspace: self, slot: slot)) }
        }
    }
}
