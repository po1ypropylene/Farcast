import SwiftUI

extension SessionState {
    var color: SwiftUI.Color {
        switch self {
        case .connected: .green
        case .failed: .red
        case .waiting, .connecting, .verifying, .authenticating, .stale, .reconnecting: .orange
        case .disconnected: .gray
        }
    }
}
