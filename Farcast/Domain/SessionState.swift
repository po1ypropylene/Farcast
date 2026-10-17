import Foundation

struct SessionLog: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}
enum SessionState: String {
    case waiting, connecting, verifying, authenticating, connected, stale, reconnecting, disconnected, failed
    var title: String { rawValue.capitalized }
    var active: Bool {
        [.waiting, .connecting, .verifying, .authenticating, .connected, .stale, .reconnecting].contains(self)
    }
}
