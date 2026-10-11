import AppKit
import SwiftTerm

@MainActor final class SSHInteractionView: TerminalView {
    static let rightClickPreference = "sshRightClickAction"
    var inputEnabled = false
    var preferences = UserDefaults.standard
    var clipboard = NSPasteboard.general
    var openSearch: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var contextText = ""
    private var contextAllowsPaste = false

    // A terminal has a remote cursor, not a local editable text model. Never
    // emulate Cut by sending deletion keys for a local scrollback selection.
    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        prepareContext(event)
        if preferences.string(forKey: Self.rightClickPreference) == "automatic" {
            if let selected = getSelection(), !selected.isEmpty {
                writeClipboard(selected)
            } else if contextAllowsPaste {
                paste(self)
            } else {
                copyContext(self)
            }
        } else if let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { super.rightMouseUp(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if reportsMouse(event) { super.rightMouseDragged(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), !reportsMouse(event) {
            rightMouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func reportsMouse(_ event: NSEvent) -> Bool {
        allowMouseReporting && currentMouseMode != .off && !event.modifierFlags.contains(.shift)
    }

    private func prepareContext(_ event: NSEvent) {
        let snapshot = terminalStateSnapshot()
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), snapshot.dimensions.cols > 0 else {
            contextText = ""
            contextAllowsPaste = false
            return
        }
        let row = characterIndex(for: event.locationInWindow) / snapshot.dimensions.cols
        contextAllowsPaste = inputEnabled && (!canScroll || scrollPosition == 1) && row == snapshot.cursor.row
        contextText = getSelection() ?? visibleRowsText(row..<(row + 1)).first ?? ""
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        prepareContext(event)
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Cut", #selector(cutContext(_:)), enabled: false)
        add("Copy", #selector(copyContext(_:)), enabled: !contextText.isEmpty)
        add("Paste", #selector(pasteContext(_:)), enabled: contextAllowsPaste && clipboardTextAvailable)
        menu.addItem(.separator())
        add("Select All", #selector(selectAll(_:)), enabled: true)
        add("Search with Google", #selector(searchContext(_:)), enabled: !contextText.isEmpty)
        return menu
    }

    // Finder can advertise both a file URL and its name as a string. Refuse
    // the entire file clipboard rather than sending that name to the shell.
    private var clipboardTextAvailable: Bool {
        let types = clipboard.types ?? []
        return !types.contains(.fileURL) && !types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            && types.contains(.string)
    }

    override func paste(_ sender: Any) {
        guard inputEnabled, clipboardTextAvailable, let text = clipboard.string(forType: .string) else { return }
        pasteText(text)
    }

    override func copy(_ sender: Any) {
        guard let text = getSelection(), !text.isEmpty else { return }
        writeClipboard(text)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)): return inputEnabled && clipboardTextAvailable
        case #selector(copy(_:)): return !(getSelection() ?? "").isEmpty
        case #selector(cutContext(_:)): return false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    private func writeClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    @objc private func cutContext(_ sender: Any?) {}
    @objc private func copyContext(_ sender: Any?) { writeClipboard(contextText) }
    @objc private func pasteContext(_ sender: Any?) {
        guard contextAllowsPaste else { return }
        paste(self)
    }
    @objc private func searchContext(_ sender: Any?) {
        guard !contextText.isEmpty else { return }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: contextText)]
        if let url = components.url { openSearch(url) }
    }
}
