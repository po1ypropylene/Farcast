import SwiftUI

/// Observe presentation state independently of the workspace's session selection.
struct SessionFullScreenButton: View {
    @ObservedObject var session: RemoteSession

    var body: some View {
        Button {
            if session.fullScreenPresented {
                session.exitFullScreen()
            } else {
                session.enterFullScreen()
            }
        } label: {
            Label(
                session.fullScreenPresented ? "Exit Remote Desktop Full Screen" : "Enter Remote Desktop Full Screen",
                systemImage: session.fullScreenPresented
                    ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
            ).labelStyle(.iconOnly).sessionActionColor(.fullScreen)
        }
        .help(
            session.fullScreenPresented
                ? "Exit Remote Desktop Full Screen (⌃⌘F)" : "Enter Remote Desktop Full Screen (⌃⌘F)"
        )
        .accessibilityLabel(
            session.fullScreenPresented ? "Exit Remote Desktop Full Screen" : "Enter Remote Desktop Full Screen"
        )
        .disabled(session.state != .connected)
    }
}
