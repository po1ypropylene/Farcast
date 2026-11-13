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
        precondition(window.makeFirstResponder(view))
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
        func validate(_ menu: NSMenu) {
            menu.update()
            for item in menu.items where !item.isSeparatorItem {
                precondition(item.isEnabled == view.validateUserInterfaceItem(item))
            }
        }
        func perform(_ item: NSMenuItem) {
            precondition(item.isEnabled)
            _ = (item.target as! NSObject).perform(item.action!, with: item)
            settle()
        }
        func key(_ type: NSEvent.EventType, code: UInt16, text: String, repeatKey: Bool = false) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: .numericPad, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code)!
        }
        let keypad: [(UInt16, String)] = [
            (82, "0"), (83, "1"), (84, "2"), (85, "3"), (86, "4"), (87, "5"),
            (88, "6"), (89, "7"), (91, "8"), (92, "9"), (65, "."), (65, ","),
            (95, ","), (67, "*"), (69, "+"), (75, "/"), (78, "-"), (81, "="), (76, "\u{3}"),
        ]
        for mode in ["\u{1b}>", "\u{1b}=", "\u{1b}[?1h\u{1b}="] {
            view.feed(text: mode)
            settle()
            for (code, text) in keypad {
                sent.removeAll()
                NSApp.sendEvent(key(.keyDown, code: code, text: text))
                NSApp.sendEvent(key(.keyDown, code: code, text: text, repeatKey: true))
                NSApp.sendEvent(key(.keyUp, code: code, text: text))
                let expected = code == 76 ? "\r" : text
                precondition(
                    String(data: sent, encoding: .utf8) == expected + expected,
                    "Keypad must type numbers/operators even in application-keypad mode")
            }
        }
        sent.removeAll()
        NSApp.sendEvent(key(.keyDown, code: 123, text: "\u{F702}"))
        NSApp.sendEvent(key(.keyUp, code: 123, text: "\u{F702}"))
        precondition(
            String(data: sent, encoding: .utf8) == "\u{1b}OD", "Separate arrows retain application-cursor behavior")
        view.feed(text: "\u{1b}[>10u")
        sent.removeAll()
        NSApp.sendEvent(key(.keyDown, code: 84, text: "2"))
        NSApp.sendEvent(key(.keyUp, code: 84, text: "2"))
        precondition(
            String(data: sent, encoding: .utf8) == "\u{1b}[50u\u{1b}[50;1:3u",
            "Enhanced keyboard mode must report the number and its matching release")
        view.feed(text: "\u{1b}[<u")
        view.inputEnabled = false
        sent.removeAll()
        NSApp.sendEvent(key(.keyDown, code: 84, text: "2"))
        precondition(sent.isEmpty)
        view.inputEnabled = true
        view.feed(text: "\u{1b}[?1l\u{1b}>")
        print(
            "PASS Apple keypad digits/operators, decimal separator, Enter, repeat and separate arrows in terminal modes"
        )

        view.feed(text: "Synthetic output 繁體 😀\r\n$ ")
        settle()
        clipboard.setString("paste text", forType: .string)
        let outputEvent = event(row: 0)
        let inputEvent = event(row: 1)
        let outputMenu = view.menu(for: outputEvent)!
        validate(outputMenu)
        precondition(view.validateUserInterfaceItem(item(outputMenu, "Copy")), "AppKit must validate context Copy")
        precondition(!item(outputMenu, "Cut").isEnabled && item(outputMenu, "Paste").isEnabled)
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
        print("PASS AppKit validates native menu copy/search/paste; cut stays disabled with no automatic side effects")

        let inputMenu = view.menu(for: inputEvent)!
        validate(inputMenu)
        precondition(item(inputMenu, "Paste").isEnabled)
        view.feed(text: "\u{1b}[?2004h")
        settle()
        clipboard.clearContents()
        clipboard.setString("first\n第二", forType: .string)
        perform(item(inputMenu, "Paste"))
        precondition(String(data: sent, encoding: .utf8) == "\u{1b}[200~first\n第二\u{1b}[201~")
        print("PASS input menu paste preserves Unicode/multiline bracketed-paste encoding")

        sent.removeAll()
        let blankMenu = view.menu(for: event(row: 5))!
        validate(blankMenu)
        precondition(item(blankMenu, "Paste").isEnabled)
        perform(item(blankMenu, "Paste"))
        precondition(String(data: sent, encoding: .utf8) == "\u{1b}[200~first\n第二\u{1b}[201~")
        view.selectAll(nil)
        let selectedMenu = view.menu(for: event(row: 5))!
        validate(selectedMenu)
        precondition(item(selectedMenu, "Copy").isEnabled)
        perform(item(selectedMenu, "Copy"))
        precondition(clipboard.string(forType: .string) == view.getSelection())
        view.selectNone()
        print("PASS blank-area menu pastes at remote cursor and preserves selected-text copy")

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
        validate(inputMenu)
        precondition(!item(inputMenu, "Paste").isEnabled)
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
        _ = view.perform(item(inputMenu, "Paste").action!, with: item(inputMenu, "Paste"))
        validate(inputMenu)
        precondition(sent.isEmpty && !item(view.menu(for: inputEvent)!, "Paste").isEnabled)
        print("PASS files plus text, nontext clipboard, and disconnect during an open menu refuse paste")

        view.inputEnabled = true
        view.feed(text: String(repeating: "\r\nHistory", count: 100) + "\r\n$ ")
        settle()
        view.scroll(toPosition: 0)
        settle()
        let scrolled = event(row: view.terminalStateSnapshot().cursor.row)
        let scrollbackMenu = view.menu(for: scrolled)!
        validate(scrollbackMenu)
        precondition(item(scrollbackMenu, "Paste").isEnabled)
        view.rightMouseDown(with: scrolled)
        precondition(sent.isEmpty)
        clipboard.clearContents()
        clipboard.setString("explicit paste", forType: .string)
        perform(item(scrollbackMenu, "Paste"))
        precondition(String(data: sent, encoding: .utf8) == "\u{1b}[200~explicit paste\u{1b}[201~")
        print("PASS scrollback permits explicit menu paste but cannot become an automatic paste target")

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
