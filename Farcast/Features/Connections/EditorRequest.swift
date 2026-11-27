import Foundation

struct EditorRequest: Identifiable {
    enum Mode { case create, edit, quick }
    let id = UUID()
    var draft: ConnectionDraft
    var mode: Mode
    var initialTab: Tab = .general
    enum Tab: String, Identifiable {
        case general, display, devices, terminal, files, tunnels, security
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .display: return "Display"
            case .devices: return "Devices & audio"
            case .files: return "Files"
            case .terminal: return "Terminal"
            case .tunnels: return "Tunnels"
            case .security: return "Security"
            }
        }
    }
}
