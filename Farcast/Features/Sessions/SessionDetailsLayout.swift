import SwiftUI

/// Keep the session in the same view hierarchy when showing or pinning details.
struct SessionDetailsLayout: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    @Binding var isPresented: Bool

    var body: some View {
        SessionPane(session: session, workspace: workspace).id(session.id)
            .padding(.trailing, isPresented && workspace.inspectorPinned ? 301 : 0)
            .overlay(alignment: .trailing) {
                if isPresented {
                    HStack(spacing: 0) {
                        Divider()
                        SessionInspector(
                            session: session, isPinned: $workspace.inspectorPinned,
                            isPresented: $isPresented
                        ).frame(width: 300)
                    }.frame(width: 301)
                }
            }
    }
}
