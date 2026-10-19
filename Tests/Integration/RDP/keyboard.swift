import AppKit
import Foundation

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
        func event(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags, text: String = "") -> NSEvent {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: key)!
        }
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
        precondition(events == ["91:false:true"])
        for (key, text, scan) in [(UInt16(8), "c", 46), (7, "x", 45), (0, "a", 30)] {
            events.removeAll()
            precondition(desktop.performKeyEquivalent(with: event(.keyDown, key: key, flags: .command, text: text)))
            precondition(events == ["29:true:false", "\(scan):true:false", "\(scan):false:false", "29:false:false"])
        }
        events.removeAll()
        desktop.keyDown(with: event(.keyDown, key: 9, flags: .control, text: "v"))
        desktop.keyUp(with: event(.keyUp, key: 9, flags: .control, text: "v"))
        precondition(events == ["prepare", "47:true:false", "47:false:false"])
        events.removeAll()
        precondition(!desktop.performKeyEquivalent(with: event(.keyDown, key: 12, flags: .command, text: "q")))
        precondition(events.isEmpty)
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
    }
}
