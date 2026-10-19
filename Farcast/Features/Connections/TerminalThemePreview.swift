import AppKit
import SwiftTerm
import SwiftUI

/// A local rendering surface; previewing an appearance never starts an SSH session.
struct TerminalThemePreview: NSViewRepresentable {
    let theme: String
    let fontSize: Double

    func makeCoordinator() -> TerminalController {
        var profile = ConnectionDraft()
        profile.terminalTheme = theme
        profile.fontSize = fontSize
        return TerminalController(profile: profile)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = context.coordinator.view
        view.setFrameSize(NSSize(width: 492, height: 300))
        view.feed(text: TerminalSample.text.replacingOccurrences(of: "\n", with: "\r\n"))
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        guard
            context.coordinator.view.font.pointSize != fontSize
                || context.coordinator.view.accessibilityIdentifier() != theme
        else { return }
        context.coordinator.applyAppearance(theme: theme, fontSize: fontSize)
        view.setAccessibilityIdentifier(theme)
    }
}
