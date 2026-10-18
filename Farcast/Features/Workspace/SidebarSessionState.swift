import SwiftUI

struct SidebarSessionState: View {
    @ObservedObject var workspace: Workspace
    let profileID: UUID
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let sessions = workspace.sessions.filter { $0.profile.id == profileID }
            let session =
                sessions.first { $0.state == .connected } ?? sessions.first { $0.state.active }
                ?? sessions.last { $0.state == .failed } ?? sessions.last
            if let session {
                let uptime =
                    session.connectedAt.map {
                        SessionUptime.string(since: $0, now: timeline.date)
                    } ?? ""
                let label = "\(session.state.title)\(uptime.isEmpty ? "" : " " + uptime)"
                Circle().fill(session.state.color)
                    .frame(width: 6, height: 6)
                    .opacity(
                        session.state.active && session.state != .connected
                            ? (Int(timeline.date.timeIntervalSince1970) % 2 == 0 ? 1 : 0.5) : 1
                    )
                    .animation(.easeInOut(duration: 0.4), value: Int(timeline.date.timeIntervalSince1970))
                    .help(label).accessibilityLabel(label)
            }
        }.frame(width: 8)
    }
}
