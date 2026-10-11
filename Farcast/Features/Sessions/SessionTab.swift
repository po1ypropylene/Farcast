import SwiftUI

struct SessionTab: View {
    @ObservedObject var session: RemoteSession
    @ObservedObject var workspace: Workspace
    private var selected: Bool { workspace.selectedSessionID == session.id }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                workspace.select(session.id)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(session.state.color).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Image(systemName: session.profile.kind.icon)
                        .font(.system(size: 12, weight: .medium))
                        .accessibilityHidden(true)
                    Text(session.profile.name).fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1).frame(maxWidth: 180)
                }
                .font(.body)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(minWidth: 24, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.profile.name), \(session.profile.kind.rawValue)")
            .accessibilityValue(session.state.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("\(session.profile.name) · \(session.state.title)")

            IconActionButton(
                title: "Close \(session.profile.name)", symbol: "xmark",
                action: {
                    workspace.close(session)
                }, size: 22
            )
            .padding(.trailing, 4)
        }
        .glassEffect(
            selected ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .clear.interactive(),
            in: Capsule()
        )
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Reconnect") { workspace.reconnect(session) }
            Button("Disconnect") { session.disconnect() }.disabled(!session.state.active)
            Button("Close") { workspace.close(session) }
        }
    }
}
