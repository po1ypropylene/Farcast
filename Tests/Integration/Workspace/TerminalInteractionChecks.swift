import AppKit
import SwiftTerm
import SwiftUI

@main struct TerminalInteractionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "com.peterpo.farcast.TerminalTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let clipboard = NSPasteboard(name: .init(suite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            clipboard.releaseGlobally()
        }
        let controller = TerminalController(profile: ConnectionDraft())
        let view = controller.view
        view.preferences = preferences
        view.clipboard = clipboard
        view.inputEnabled = true
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var sent = Data()
        controller.sendBytes = { sent.append($0) }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            view.layoutSubtreeIfNeeded()
        }
        func event(row: Int, type: NSEvent.EventType = .rightMouseDown, modifiers: NSEvent.ModifierFlags = [])
            -> NSEvent
        {
            let cellHeight = view.caretFrame.height
            let point = NSPoint(x: 4, y: view.bounds.height - (CGFloat(row) + 0.5) * cellHeight)
            return NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!
        }
        func item(_ menu: NSMenu, _ title: String) -> NSMenuItem { menu.items.first { $0.title == title }! }
        func perform(_ item: NSMenuItem) {
            precondition(item.isEnabled)
            _ = (item.target as! NSObject).perform(item.action!, with: item)
            settle()
        }
        view.feed(text: "Synthetic output 繁體 😀\r\n$ ")
        settle()
        clipboard.setString("paste text", forType: .string)
        let outputEvent = event(row: 0)
        let inputEvent = event(row: 1)
        let outputMenu = view.menu(for: outputEvent)!
        precondition(!item(outputMenu, "Cut").isEnabled && !item(outputMenu, "Paste").isEnabled)
        precondition(item(outputMenu, "Copy").isEnabled && item(outputMenu, "Search with Google").isEnabled)
        precondition(sent.isEmpty && clipboard.string(forType: .string) == "paste text")
        perform(item(outputMenu, "Copy"))
        precondition(clipboard.string(forType: .string) == "Synthetic output 繁體 😀")
        var searchURL: URL?
        view.openSearch = { searchURL = $0 }
        perform(item(outputMenu, "Search with Google"))
        precondition(
            URLComponents(url: searchURL!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                == "Synthetic output 繁體 😀")
        print("PASS native menu output copy/search, disabled cut/paste, no automatic side effects")

        let inputMenu = view.menu(for: inputEvent)!
        precondition(item(inputMenu, "Paste").isEnabled)
        view.feed(text: "\u{1b}[?2004h")
        settle()
        clipboard.clearContents()
        clipboard.setString("first\n第二", forType: .string)
        perform(item(inputMenu, "Paste"))
        precondition(String(data: sent, encoding: .utf8) == "\u{1b}[200~first\n第二\u{1b}[201~")
        print("PASS input menu paste preserves Unicode/multiline bracketed-paste encoding")

        sent.removeAll()
        preferences.set("automatic", forKey: SSHInteractionView.rightClickPreference)
        view.rightMouseDown(with: inputEvent)
        settle()
        precondition(!sent.isEmpty)
        sent.removeAll()
        view.rightMouseDown(with: outputEvent)
        precondition(sent.isEmpty && clipboard.string(forType: .string) == "Synthetic output 繁體 😀")
        view.selectAll(nil)
        let selection = view.getSelection()!
        view.rightMouseDown(with: inputEvent)
        precondition(sent.isEmpty && clipboard.string(forType: .string) == selection)
        view.selectNone()
        print("PASS live preference change, automatic cursor paste/output copy, selection precedence")

        clipboard.clearContents()
        clipboard.setString("file:///fixture.txt", forType: .fileURL)
        clipboard.setString("fixture.txt", forType: .string)
        view.rightMouseDown(with: inputEvent)
        view.paste(view)
        settle()
        precondition(sent.isEmpty && !item(view.menu(for: inputEvent)!, "Paste").isEnabled)
        clipboard.clearContents()
        clipboard.setData(Data([0, 1]), forType: .png)
        view.paste(view)
        settle()
        precondition(sent.isEmpty)
        clipboard.clearContents()
        clipboard.setString("text", forType: .string)
        view.inputEnabled = false
        view.paste(view)
        perform(item(inputMenu, "Paste"))
        precondition(sent.isEmpty && !item(view.menu(for: inputEvent)!, "Paste").isEnabled)
        print("PASS files plus text, nontext clipboard, and disconnect during an open menu refuse paste")

        view.inputEnabled = true
        view.feed(text: String(repeating: "\r\nHistory", count: 100) + "\r\n$ ")
        settle()
        view.scroll(toPosition: 0)
        settle()
        let scrolled = event(row: view.terminalStateSnapshot().cursor.row)
        precondition(!item(view.menu(for: scrolled)!, "Paste").isEnabled)
        view.rightMouseDown(with: scrolled)
        precondition(sent.isEmpty)
        print("PASS scrollback cannot become an automatic paste target")

        view.scroll(toPosition: 1)
        view.feed(text: "\u{1b}[?1000h")
        settle()
        sent.removeAll()
        view.rightMouseDown(with: event(row: 0))
        view.rightMouseUp(with: event(row: 0, type: .rightMouseUp))
        settle()
        precondition(!sent.isEmpty)
        sent.removeAll()
        view.rightMouseDown(with: event(row: 0, modifiers: .shift))
        settle()
        precondition(sent.isEmpty)
        print("PASS remote mouse reporting and Shift local override")

        let settings = NSHostingView(rootView: AppSettings().defaultAppStorage(preferences))
        settings.frame = NSRect(x: 0, y: 0, width: 512, height: 452)
        window.contentView = settings
        settle()
        precondition(preferences.string(forKey: SSHInteractionView.rightClickPreference) == "automatic")
        print("PASS production Settings hosts the persistent right-click preference")
    }
}
