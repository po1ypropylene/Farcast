import AppKit
import MetalKit

@main struct DisplayPresentationChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let desktop = RDPDesktopView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        desktop.inputEnabled = true
        var pointer: CGPoint?
        desktop.sendPointer = { _, x, y in pointer = CGPoint(x: x, y: y) }
        // Off-screen, owned native windows avoid taking over the user's displays.
        let screens: [RDPDisplayScreen] = [
            .init(id: 1, frame: CGRect(x: -30000, y: -30000, width: 800, height: 600), backingScale: 2),
            .init(id: 2, frame: CGRect(x: -30800, y: -30000, width: 800, height: 600), backingScale: 1),
        ]
        let layout = try RDPDisplayLayout(screens: screens, retina: true)
        let presentation = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        var exited = false
        presentation.onExit = { _ in exited = true }
        presentation.show()
        precondition(presentation.windows.count == 2 && presentation.surfaces.count == 2 && desktop.isPaused)
        let primary = presentation.surfaces[0]
        let left = presentation.surfaces[1]
        precondition(primary.mailbox === desktop.mailbox && left.mailbox === desktop.mailbox)
        precondition(primary.sourceRect == CGRect(x: 800, y: 0, width: 1600, height: 1200))
        precondition(left.sourceRect == CGRect(x: 0, y: 300, width: 800, height: 600))
        print("PASS full-screen targets share one bounded mailbox, with distinct mixed-DPI source regions")
        var pixels = Data(count: 2400 * 1200 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let raw = bytes.bindMemory(to: UInt8.self)
            for y in 0..<1200 {
                for x in 0..<2400 {
                    let offset = (y * 2400 + x) * 4
                    raw[offset] = UInt8(x % 256)
                    raw[offset + 1] = UInt8(y % 256)
                    raw[offset + 2] = 96
                    raw[offset + 3] = 255
                }
            }
        }
        desktop.submit(pixels, width: 2400, height: 1200, stride: 2400 * 4)
        primary.draw(in: primary)
        left.draw(in: left)
        precondition(primary.texture?.width == 1600 && primary.texture?.height == 1200)
        precondition(left.texture?.width == 800 && left.texture?.height == 600)
        var first = [UInt8](repeating: 0, count: 4)
        first.withUnsafeMutableBytes {
            primary.texture!.getBytes(
                $0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [32, 0, 96, 255])
        first.withUnsafeMutableBytes {
            left.texture!.getBytes($0.baseAddress!, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        }
        precondition(first == [0, 44, 96, 255])
        print("PASS production Metal upload crops marked framebuffer pixels without duplicating full-desktop textures")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        precondition(presentation.surfaces.allSatisfy { $0.isPaused && $0.texture == nil })
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        precondition(presentation.surfaces.allSatisfy { !$0.isPaused })
        primary.draw(in: primary)
        left.draw(in: left)
        precondition(primary.texture?.width == 1600 && left.texture?.width == 800)
        print("PASS inactive full-screen surfaces retire GPU textures and resume from the shared latest frame")
        for (index, surface) in presentation.surfaces.enumerated() {
            let window = presentation.windows[index]
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: CGPoint(x: 400, y: 300), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0)!
            surface.mouseMoved(with: event)
            precondition(pointer == CGPoint(x: index == 0 ? 1600 : 400, y: 600))
        }
        let sourceWindow = presentation.windows[0]
        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: -400, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        primary.mouseDragged(with: drag)
        precondition(pointer == CGPoint(x: 400, y: 600))
        var releases = 0
        primary.sendPointer = { flags, _, _ in if flags == 0x1000 { releases += 1 } }
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 400, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: sourceWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        primary.mouseDown(with: down)
        primary.releaseInput()
        primary.releaseInput()
        precondition(releases == 1)
        print("PASS cross-monitor drag routing and focus-loss release keep remote mouse buttons balanced")
        left.setFrameSize(CGSize(width: 1000, height: 600))
        pointer = nil
        let padding = NSEvent.mouseEvent(
            with: .mouseMoved, location: CGPoint(x: 20, y: 300), modifierFlags: [], timestamp: 0,
            windowNumber: presentation.windows[1].windowNumber, context: nil, eventNumber: 0,
            clickCount: 0, pressure: 0)!
        left.mouseMoved(with: padding)
        precondition(pointer == nil)
        print("PASS production input inverts monitor crop, Retina density and Y orientation, and rejects letterboxing")
        // A reconfigured frame must never be uploaded using the previous crop transform.
        desktop.submit(Data(count: 800 * 600 * 4), width: 800, height: 600, stride: 800 * 4)
        primary.draw(in: primary)
        precondition(primary.texture == nil)
        pointer = nil
        primary.sendPointer = { _, x, y in pointer = CGPoint(x: x, y: y) }
        primary.mouseMoved(with: padding)
        precondition(pointer == nil)
        let windows = presentation.windows
        presentation.exit()
        precondition(exited && presentation.windows.isEmpty && presentation.surfaces.isEmpty && !desktop.isPaused)
        precondition(windows.allSatisfy { !$0.isVisible })
        presentation.exit(notify: false)
        print("PASS obsolete frame rejection and idempotent full-screen teardown leave the session surface reusable")
        let changed = RDPFullScreenPresentation(desktop: desktop, screens: screens, layout: layout)
        var reason: String?
        changed.onExit = { reason = $0 }
        changed.show()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        precondition(changed.windows.isEmpty && reason?.lowercased().contains("reconnect") == true && !desktop.isPaused)
        print("PASS topology change returns to the existing surface with an explicit reconnect notice")

    }
}
