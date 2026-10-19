import Foundation

enum RemoteProtocol: String, Codable, CaseIterable, Identifiable {
    case ssh = "SSH"
    case rdp = "RDP"
    case vnc = "VNC"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .ssh: return "terminal"
        case .rdp: return "display"
        case .vnc: return "rectangle.on.rectangle"
        }
    }
    var defaultPort: Int {
        switch self {
        case .ssh: return 22
        case .rdp: return 3389
        case .vnc: return 5900
        }
    }
}
