import AppKit
import MetalKit

/// Native full-screen close must not strand the persistent Metal view's display link.
@MainActor private final class ReturnDelegate: NSObject, NSWindowDelegate {
    let main: NSWindow
    let desktop: RDPDesktopView
    init(main: NSWindow, desktop: RDPDesktopView) {
        self.main = main
        self.desktop = desktop
    }
    func windowWillClose(_ notification: Notification) {
        main.contentView = RDPViewport(desktop: desktop)
        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(desktop)
    }
}

@main struct WindowReturnChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        func makeWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        func settle(_ seconds: TimeInterval = 0.4) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let desktop = RDPDesktopView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        desktop.inputEnabled = true
        let window = makeWindow()
        window.contentView = RDPViewport(desktop: desktop)
        window.makeKeyAndOrderFront(nil)
        app.activate()
        let delegate = ReturnDelegate(main: window, desktop: desktop)
        defer { window.close() }
        func frame(_ marker: UInt8) {
            desktop.submit(Data(repeating: marker, count: 640 * 480 * 4), width: 640, height: 480, stride: 640 * 4)
            settle()
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                desktop.texture?.getBytes(
                    $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            }
            precondition(pixel[0] == marker, "New frames must render without forcing a draw after window return")
        }
        settle()
        frame(21)
        for fullScreen in [false, true, true] {
            let detached = makeWindow()
            detached.delegate = delegate
            detached.contentView = RDPViewport(desktop: desktop)
            detached.makeKeyAndOrderFront(nil)
            settle()
            frame(31)
            if fullScreen {
                var entered = false
                let observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification, object: detached, queue: .main
                ) { _ in MainActor.assumeIsolated { entered = true } }
                detached.toggleFullScreen(nil)
                let deadline = Date().addingTimeInterval(8)
                while !entered && Date() < deadline { settle(0.05) }
                NotificationCenter.default.removeObserver(observer)
                precondition(entered, "Fixture must actually enter macOS full screen")
            }
            detached.performClose(nil)
            settle()
            precondition(desktop.window === window && !desktop.renderingSuspended)
            frame(41)
            frame(51)
            // Bursts publish the latest frame rather than queueing one UI callback per frame.
            for marker: UInt8 in 60...90 {
                desktop.submit(Data(repeating: marker, count: 640 * 480 * 4), width: 640, height: 480, stride: 640 * 4)
            }
            settle()
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                desktop.texture?.getBytes(
                    $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            }
            precondition(pixel[0] == 90)
            var clicks = 0
            var keys = 0
            desktop.sendPointer = { _, _, _ in clicks += 1 }
            desktop.sendKey = { _, _, _ in keys += 1 }
            let click = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: desktop.convert(CGPoint(x: desktop.bounds.midX, y: desktop.bounds.midY), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 0)!
            desktop.mouseDown(with: click)
            desktop.mouseUp(with: click)
            let key = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            desktop.keyDown(with: key)
            desktop.keyUp(with: key)
            precondition(clicks >= 2 && keys == 2 && window.firstResponder === desktop)
            print(
                "PASS close from \(fullScreen ? "macOS full screen" : "detached window") preserves new frames, burst coalescing, mouse and keyboard"
            )
        }
    }
}
