import SwiftUI

struct SessionDisconnectButton: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    var compact = false
    var body: some View {
        Group {
            if compact {
                IconActionButton(title: "Disconnect (⇧⌘D)", symbol: "power") { workspace.requestDisconnect(session) }
            } else {
                Button {
                    workspace.requestDisconnect(session)
                } label: {
                    Label("Disconnect", systemImage: "power").labelStyle(.iconOnly)
                }.help("Disconnect (⇧⌘D)").accessibilityLabel("Disconnect")
            }
        }.disabled(!session.state.active)
    }
}
