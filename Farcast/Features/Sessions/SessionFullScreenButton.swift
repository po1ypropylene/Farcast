import SwiftUI

/// Observe presentation state independently of the workspace's session selection.
struct SessionFullScreenButton: View {
    @ObservedObject var session: RemoteSession

    var body: some View {
        IconActionButton(
            title: session.fullScreenPresented
                ? "Exit Remote Desktop Full Screen (⌃⌘F)" : "Enter Remote Desktop Full Screen (⌃⌘F)",
            symbol: session.fullScreenPresented
                ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        ) {
            if session.fullScreenPresented {
                session.exitFullScreen()
            } else {
                session.enterFullScreen()
            }
        }.disabled(session.state != .connected)
    }
}
