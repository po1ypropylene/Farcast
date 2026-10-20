import SwiftUI

/// Shared by native toolbar labels and compact detached-window controls.
enum SessionActionColor {
    case quickConnect, reconnect, disconnect, fullScreen, details, popOut

    func color(dark: Bool, increasedContrast: Bool) -> Color {
        let rgb: (Double, Double, Double)
        switch self {
        case .quickConnect: rgb = dark ? (1, 0.78, 0.38) : (0.57, 0.32, 0)
        case .reconnect: rgb = dark ? (0.40, 0.86, 0.53) : (0.12, 0.43, 0.22)
        case .disconnect: rgb = dark ? (1, 0.48, 0.48) : (0.75, 0.16, 0.18)
        case .fullScreen: rgb = dark ? (0.35, 0.85, 0.86) : (0, 0.42, 0.46)
        case .details: rgb = dark ? (0.48, 0.73, 1) : (0.16, 0.36, 0.72)
        case .popOut: rgb = dark ? (0.77, 0.65, 1) : (0.47, 0.28, 0.70)
        }
        func channel(_ value: Double) -> Double {
            guard increasedContrast else { return value }
            return dark ? value + (1 - value) * 0.25 : value * 0.8
        }
        return Color(.sRGB, red: channel(rgb.0), green: channel(rgb.1), blue: channel(rgb.2))
    }
}

private struct SessionActionForeground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled
    let action: SessionActionColor

    func body(content: Content) -> some View {
        content.foregroundStyle(
            enabled ? action.color(dark: scheme == .dark, increasedContrast: contrast == .increased) : Color.secondary)
    }
}

extension View {
    func sessionActionColor(_ action: SessionActionColor) -> some View {
        modifier(SessionActionForeground(action: action))
    }
}
