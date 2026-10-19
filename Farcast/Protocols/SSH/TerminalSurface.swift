import AppKit
import SwiftTerm
import SwiftUI

@MainActor final class TerminalController: NSObject, TerminalViewDelegate {
    let view: SSHInteractionView
    var sendBytes: ((Data) -> Void)?
    var resize: ((Int, Int) -> Void)?
    var updateTitle: ((String) -> Void)?
    init(profile: ConnectionDraft) {
        view = SSHInteractionView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 600),
            font: NSFont.monospacedSystemFont(ofSize: profile.fontSize, weight: .regular),
            options: TerminalOptions(scrollback: 10_000))
        super.init()
        view.terminalDelegate = self
        applyAppearance(theme: profile.terminalTheme, fontSize: profile.fontSize)
    }
    func applyAppearance(theme: String, fontSize: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        switch theme {
        case "Paper":
            view.nativeBackgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
            view.nativeForegroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        case "Solarized":
            view.nativeBackgroundColor = NSColor(red: 0, green: 0.17, blue: 0.21, alpha: 1)
            view.nativeForegroundColor = NSColor(red: 0.51, green: 0.58, blue: 0.59, alpha: 1)
        default:
            view.nativeBackgroundColor = NSColor(red: 0.055, green: 0.071, blue: 0.102, alpha: 1)
            view.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { resize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { updateTitle?(String(title.prefix(120))) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { sendBytes?(Data(data)) }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
    func bell(source: TerminalView) { NSSound.beep() }
    // Remote terminal escape sequences cannot read or replace the local clipboard.
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func zoom(_ delta: Double) {
        view.font = NSFont.monospacedSystemFont(ofSize: min(32, max(9, view.font.pointSize + delta)), weight: .regular)
    }
    func find() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        view.performFindPanelAction(item)
    }
}
struct TerminalSurface: NSViewRepresentable {
    let controller: TerminalController
    func makeNSView(context: Context) -> TerminalView { controller.view }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
