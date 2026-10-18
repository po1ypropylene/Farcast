import SwiftData
import SwiftUI

/// Describes this session's VPN lease, which can stop while another session keeps the helper alive.
struct SessionVPNStatus: View {
    @ObservedObject var session: RemoteSession
    @Query private var profiles: [SavedWireGuard]

    var body: some View {
        if let id = session.profile.wireGuardID {
            let profile = profiles.first { $0.id == id }
            let name = profile?.name ?? "Unavailable profile"
            let status = session.vpnState == .connected ? "Ready" : session.vpnState.title
            HStack(spacing: 5) {
                Circle().fill(session.vpnState.color).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("VPN: \(name) · \(status)").lineLimit(1).truncationMode(.middle)
            }
            .help(
                "\(name) · \(status). Status of this session’s VPN transport; Ready means its destination lease is available."
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("VPN: \(name), \(status)")
        }
    }
}
