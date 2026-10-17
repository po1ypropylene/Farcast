import SwiftUI

extension SessionState {
    var color: SwiftUI.Color {
        switch self {
        case .connected: .green
        case .failed, .stale: .orange
        case .waiting, .connecting, .verifying, .authenticating, .reconnecting: .blue
        case .disconnected: .gray
        }
    }
}
