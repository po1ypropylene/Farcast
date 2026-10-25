import AppKit
import Foundation
import IOKit.hidsystem

@main struct RDPKeyboardTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        let desktop = RDPDesktopView(frame: window.contentView!.bounds)
        window.contentView = desktop
        precondition(window.makeFirstResponder(desktop))
        desktop.inputEnabled = true
        var events: [String] = []
        desktop.sendKey = { code, down, extended in events.append("\(code):\(down):\(extended)") }
        desktop.preparePaste = { events.append("prepare") }
        func event(
            _ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags, text: String = "",
            repeatKey: Bool = false
        ) -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: key)!
        }
        let leftShift = NSEvent.ModifierFlags.shift.union(.init(rawValue: UInt(NX_DEVICELSHIFTKEYMASK)))
        let rightShift = NSEvent.ModifierFlags.shift.union(.init(rawValue: UInt(NX_DEVICERSHIFTKEYMASK)))
        let bothShift = leftShift.union(rightShift)
        // Repeated notifications are snapshots, not alternating down/up events.
        for _ in 0..<5 { desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: leftShift)) }
        precondition(events == ["42:true:false"], "Duplicate modifier snapshots must not generate Shift taps")
        desktop.flagsChanged(with: event(.flagsChanged, key: 60, flags: bothShift))
        desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: rightShift))
        desktop.flagsChanged(with: event(.flagsChanged, key: 60, flags: []))
        precondition(events == ["42:true:false", "54:true:false", "42:false:false", "54:false:false"])
        events.removeAll()
        for (key, flag, mask, scan, extended) in [
            (UInt16(59), NSEvent.ModifierFlags.control, NX_DEVICELCTLKEYMASK, 29, false),
            (62, .control, NX_DEVICERCTLKEYMASK, 29, true),
            (58, .option, NX_DEVICELALTKEYMASK, 56, false),
            (61, .option, NX_DEVICERALTKEYMASK, 56, true),
            (55, .command, NX_DEVICELCMDKEYMASK, 91, true),
            (54, .command, NX_DEVICERCMDKEYMASK, 92, true),
        ] {
            let flags = flag.union(.init(rawValue: UInt(mask)))
            desktop.flagsChanged(with: event(.flagsChanged, key: key, flags: flags))
            desktop.flagsChanged(with: event(.flagsChanged, key: key, flags: flags))
            desktop.flagsChanged(with: event(.flagsChanged, key: key, flags: []))
            precondition(events == ["\(scan):true:\(extended)", "\(scan):false:\(extended)"])
            events.removeAll()
        }
        // Each capital has a physical letter between Shift down/up, rather than
        // Unicode-only text leaving Windows to count isolated Shift presses.
        for _ in 0..<5 {
            desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: leftShift))
            desktop.keyDown(with: event(.keyDown, key: 0, flags: leftShift, text: "A"))
            desktop.keyUp(with: event(.keyUp, key: 0, flags: leftShift, text: "A"))
            desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: []))
        }
        precondition(
            events
                == Array(repeating: ["42:true:false", "30:true:false", "30:false:false", "42:false:false"], count: 5)
                .flatMap { $0 })
        events.removeAll()
        // A missing release is repaired by the next event's actual flags.
        desktop.flagsChanged(with: event(.flagsChanged, key: 59, flags: .control))
        desktop.keyDown(with: event(.keyDown, key: 123, flags: []))
        desktop.keyUp(with: event(.keyUp, key: 123, flags: []))
        precondition(events == ["29:true:false", "29:false:false", "75:true:true", "75:false:true"])
        events.removeAll()
        desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: leftShift))
        desktop.keyDown(with: event(.keyDown, key: 123, flags: leftShift))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        precondition(events == ["42:true:false", "75:true:true", "75:false:true", "42:false:false"])
        events.removeAll()
        // Held modifiers are restored from the next event after focus returns.
        desktop.keyDown(with: event(.keyDown, key: 124, flags: rightShift))
        desktop.keyUp(with: event(.keyUp, key: 124, flags: rightShift))
        desktop.inputEnabled = false
        precondition(events == ["54:true:false", "77:true:true", "77:false:true", "54:false:false"])
        desktop.flagsChanged(with: event(.flagsChanged, key: 56, flags: leftShift))
        desktop.inputEnabled = true
        events.removeAll()
        var caps: [Bool] = []
        desktop.synchronizeCapsLock = { caps.append($0) }
        desktop.flagsChanged(with: event(.flagsChanged, key: 57, flags: .capsLock))
        desktop.flagsChanged(with: event(.flagsChanged, key: 57, flags: .capsLock))
        desktop.flagsChanged(with: event(.flagsChanged, key: 57, flags: []))
        precondition(caps == [true, false] && events.isEmpty)
        desktop.releaseInput()
        desktop.keyDown(with: event(.keyDown, key: 123, flags: []))
        desktop.keyUp(with: event(.keyUp, key: 123, flags: []))
        precondition(caps == [true, false, false], "Focus return resynchronizes toggle state")
        events.removeAll()
        var unicode: [String] = []
        desktop.sendUnicode = { unit, down in unicode.append("\(unit):\(down)") }
        desktop.setMarkedText(
            "中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        desktop.insertText("中文😀", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(unicode == "中文😀".utf16.flatMap { ["\($0):true", "\($0):false"] })
        precondition(!desktop.hasMarkedText() && events.isEmpty)
        unicode.removeAll()
        desktop.keyDown(with: event(.keyDown, key: 0, flags: [], text: "é"))
        desktop.keyUp(with: event(.keyUp, key: 0, flags: [], text: "é"))
        precondition(events.isEmpty && unicode == ["233:true", "233:false"], "Non-US committed text stays Unicode")
        desktop.setMarkedText(
            "中", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        precondition(!desktop.hasMarkedText(), "Abandoned composition must not capture later typing")
        // Native window dispatch must deliver one press per event and one final
        // release even when keyDown repeats while held.
        window.sendEvent(event(.keyDown, key: 0, flags: [], text: "a"))
        window.sendEvent(event(.keyDown, key: 0, flags: [], text: "a", repeatKey: true))
        window.sendEvent(event(.keyUp, key: 0, flags: [], text: "a"))
        precondition(events == ["30:true:false", "30:true:false", "30:false:false"])
        events.removeAll()
        // A real Command press is first forwarded as Windows; the editing shortcut must release it.
        desktop.flagsChanged(with: event(.flagsChanged, key: 55, flags: .command))
        events.removeAll()
        precondition(desktop.performKeyEquivalent(with: event(.keyDown, key: 9, flags: .command, text: "v")))
        precondition(
            events == [
                "91:false:true", "prepare", "29:true:false", "47:true:false", "47:false:false", "29:false:false",
            ])
        events.removeAll()
        desktop.flagsChanged(with: event(.flagsChanged, key: 55, flags: []))
        precondition(events.isEmpty)
        for (key, text, scan) in [(UInt16(8), "c", 46), (7, "x", 45), (0, "a", 30)] {
            events.removeAll()
            precondition(desktop.performKeyEquivalent(with: event(.keyDown, key: key, flags: .command, text: text)))
            precondition(events == ["29:true:false", "\(scan):true:false", "\(scan):false:false", "29:false:false"])
        }
        events.removeAll()
        desktop.keyDown(with: event(.keyDown, key: 9, flags: .control, text: "v"))
        desktop.keyUp(with: event(.keyUp, key: 9, flags: .control, text: "v"))
        precondition(events == ["29:true:false", "prepare", "47:true:false", "47:false:false"])
        desktop.releaseInput()
        events.removeAll()
        precondition(!desktop.performKeyEquivalent(with: event(.keyDown, key: 12, flags: .command, text: "q")))
        precondition(events.isEmpty)
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu()
        let quickConnect = NSMenuItem(title: "Synthetic Quick Connect", action: nil, keyEquivalent: "k")
        quickConnect.keyEquivalentModifierMask = .command
        menu.addItem(quickConnect)
        NSApp.mainMenu = menu
        precondition(!desktop.performKeyEquivalent(with: event(.keyDown, key: 40, flags: .command, text: "k")))
        precondition(events.isEmpty, "Registered app shortcuts must not reach Windows")
        NSApp.mainMenu = previousMenu
        desktop.flagsChanged(with: event(.flagsChanged, key: 55, flags: []))
        desktop.releaseInput()
        events.removeAll()
        // Command equivalents may have no keyUp at all. Repeats must remain
        // balanced taps without waiting for focus loss or releasing Command.
        for repeatKey in [false, true] {
            precondition(
                desktop.performKeyEquivalent(
                    with: event(.keyDown, key: 123, flags: .command, repeatKey: repeatKey)))
        }
        desktop.flagsChanged(with: event(.flagsChanged, key: 55, flags: []))
        precondition(
            events == [
                "91:true:true", "75:true:true", "75:false:true",
                "75:true:true", "75:false:true", "91:false:true",
            ], "Forwarded Command equivalents must not leave the remote nonmodifier held")
        let balanced = events
        desktop.keyUp(with: event(.keyUp, key: 123, flags: []))
        desktop.releaseInput()
        precondition(events == balanced, "A late keyUp/focus release must not duplicate the balanced release")
        events.removeAll()
        desktop.inputEnabled = false
        precondition(!desktop.performKeyEquivalent(with: event(.keyDown, key: 9, flags: .command, text: "v")))
        precondition(events.isEmpty)
        // Actual-size scrolling must preserve remote pointer coordinates after panning.
        desktop.displayMode = .actualSize
        desktop.setDesktopSize(CGSize(width: 1200, height: 900))
        let viewport = RDPViewport(desktop: desktop)
        window.contentView = viewport
        viewport.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        viewport.layoutDesktop()
        precondition(desktop.frame.size == CGSize(width: 1200, height: 900))
        precondition(viewport.hasHorizontalScroller && viewport.hasVerticalScroller)
        viewport.contentView.scroll(to: NSPoint(x: 200, y: 400))
        viewport.reflectScrolledClipView(viewport.contentView)
        desktop.inputEnabled = true
        var pointer: (Int, Int)?
        desktop.sendPointer = { _, x, y in pointer = (x, y) }
        let location = desktop.convert(NSPoint(x: 250, y: 650), to: nil)
        let mouse = NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)!
        desktop.mouseMoved(with: mouse)
        precondition(pointer?.0 == 250 && pointer?.1 == 250)
        var resizes = 0
        desktop.resizeRemote = { _, _, _ in resizes += 1 }
        desktop.requestResize()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(resizes == 0)
        desktop.displayMode = .matchWindow
        var initial: CGSize?
        desktop.withInitialSize(width: 1440, height: 900) { initial = $0 }
        precondition(
            initial
                == CGSize(
                    width: viewport.contentView.bounds.width.rounded(.down),
                    height: viewport.contentView.bounds.height.rounded(.down)))
        viewport.frame.size = CGSize(width: 300, height: 200)
        viewport.layoutDesktop()
        precondition(desktop.desktopSize == initial!)
        desktop.displayMode = .fit
        viewport.layoutDesktop()
        precondition(desktop.frame.size == viewport.contentView.bounds.size)
        // A viewport may settle after the surface has already acquired its final
        // size during reparenting. Its layout must still publish that geometry.
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        settle()
        var requestedSize: CGSize?
        desktop.resizeRemote = { width, height, _ in requestedSize = CGSize(width: width, height: height) }
        let destination = CGSize(width: 600, height: 400)
        desktop.setFrameSize(destination)
        settle()
        requestedSize = nil
        viewport.frame.size = destination
        viewport.layoutDesktop()
        settle()
        precondition(requestedSize == destination, "Settled viewport must publish geometry without a surface resize")
        print("PASS RDP viewport publishes final geometry when the reparented surface already has its fitted size")
        print(
            "PASS RDP display: 100% scrolling, panned pointer coordinates, fixed resolution, initial window size, fit")
        print(
            "PASS RDP keyboard: editing shortcuts, paste ordering, modifier release, app shortcuts, disconnected input")
        desktop.releaseInput()
        events.removeAll()
        desktop.usesTextKeySymbols = true
        var keySymbols: [String] = []
        desktop.sendText = { keySymbols.append($0) }
        for (flags, text, key) in [
            (leftShift, "A", UInt16(0)), (.capsLock, "A", 0),
            (leftShift.union(.capsLock), "a", 0), (leftShift, "!", 18),
            (NSEvent.ModifierFlags(), "a", 0),
        ] {
            desktop.keyDown(with: event(.keyDown, key: key, flags: flags, text: text))
            desktop.keyUp(with: event(.keyUp, key: key, flags: flags, text: text))
        }
        precondition(keySymbols == ["A", "A", "a", "!", "a"], "RFB keeps committed Shift/Caps Lock symbols")
        print("PASS VNC committed keysyms preserve Shift, Caps Lock, Shift+Caps Lock and punctuation")
        precondition(
            !events.contains("30:true:false") && !events.contains("2:true:false"),
            "RFB printable text must not fall back to lowercase/unshifted scan codes")
        desktop.releaseInput()
        var special: [(UInt32, Bool)] = []
        desktop.keySymbolForEvent = { _, text in text == "\u{F730}" ? 0xFF13 : nil }
        desktop.sendKeySymbol = { special.append(($0, $1)) }
        let pause = event(.keyDown, key: 113, flags: [], text: "\u{F730}")
        desktop.keyDown(with: pause)
        desktop.keyDown(with: pause)
        desktop.releaseInput()
        desktop.keyUp(with: event(.keyUp, key: 113, flags: [], text: "\u{F730}"))
        precondition(special.map { $0.0 } == [0xFF13, 0xFF13, 0xFF13])
        precondition(
            special.map { $0.1 } == [true, true, false], "Native special-key repeat and focus cleanup balance releases")
        special.removeAll()
        desktop.keySymbolForEvent = { _, text in text == "q" ? 0x71 : 0x51 }
        desktop.keyDown(with: event(.keyDown, key: 0, flags: .control, text: "q"))
        desktop.keyDown(with: event(.keyDown, key: 0, flags: [.control, .shift], text: "Q", repeatKey: true))
        desktop.keyUp(with: event(.keyUp, key: 0, flags: [.control, .shift], text: "Q"))
        precondition(special.map { $0.0 } == [0x71, 0x71, 0x51, 0x51])
        precondition(
            special.map { $0.1 } == [true, false, true, false],
            "Shift changes during shortcut repeat release the previous keysym")
        print("PASS VNC semantic special-key repeat, layout shortcut changes and focus-loss release")
        print(
            "PASS RDP keyboard: duplicate/overlapping modifiers, Shift-letter sequences, lost-release recovery, focus loss, Caps Lock sync, Unicode pairs and native window key repeat"
        )
    }
}
