import SwiftUI

struct SessionDisconnectButton: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    var compact = false
    var body: some View {
        Group {
            if compact {
                IconActionButton(title: "Disconnect Session (⇧⌘D)", symbol: "power") {
                    workspace.requestDisconnect(session)
                }
            } else {
                Button {
                    workspace.requestDisconnect(session)
                } label: {
                    Label("Disconnect Session", systemImage: "power").labelStyle(.iconOnly)
                }.help("Disconnect Session (⇧⌘D)").accessibilityLabel("Disconnect Session")
            }
        }.disabled(!session.state.active)
    }
}
