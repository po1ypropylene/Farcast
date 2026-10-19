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
                    ConnectionProtocolIcon(
                        kind: session.profile.kind,
                        routed: session.profile.wireGuardID != nil, vpnState: session.vpnState
                    )
                    .scaleEffect(0.8).frame(width: 18, height: 18)
                    if session.hasUnreadOutput {
                        Image(systemName: "waveform").font(.caption).foregroundStyle(.secondary)
                            .help("New terminal output").accessibilityLabel("New terminal output")
                    }
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
            .accessibilityValue(session.state.title + (session.hasUnreadOutput ? ", new terminal output" : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help("\(session.profile.name) · \(session.state.title)")

            IconActionButton(
                title: "Close \(session.profile.name)", symbol: "xmark",
                action: {
                    workspace.requestClose(session)
                }, size: 22
            )
            .padding(.trailing, 4)
        }
        .background(
            selected ? Color(nsColor: .controlBackgroundColor) : Color.clear,
            in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
        )
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
                .strokeBorder(selected ? Color.primary.opacity(0.18) : Color.clear, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Reconnect") { workspace.requestReconnect(session) }
            Button("Disconnect") { workspace.requestDisconnect(session) }.disabled(!session.state.active)
            Button("Close") { workspace.requestClose(session) }
        }
    }
}
