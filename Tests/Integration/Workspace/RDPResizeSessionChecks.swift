import AppKit
import CryptoKit
import Foundation

@main struct RDPResizeSessionChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let port = Int(CommandLine.arguments[1])!
        let pem = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        let pin =
            "SHA256:"
            + Data(SHA256.hash(data: Data(base64Encoded: body)!)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let mode = CommandLine.arguments[4]
        let suite = "com.peterpo.farcast.RDPResizeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(loadCredential: { _ in nil }, defaults: defaults)
        var draft = ConnectionDraft()
        draft.host = "127.0.0.1"
        draft.port = port
        draft.username = "fixture"
        draft.kind = .rdp
        draft.displayMode = mode == "actualSize" ? .actualSize : (mode == "matchWindow" ? .matchWindow : .fit)
        draft.dynamicResolution = true
        draft.retinaDisplay = mode == "retina"
        draft.desktopWidth = 640
        draft.desktopHeight = 480
        draft.clipboard = false
        draft.audioPlayback = false
        workspace.trust.remember(pin, for: draft.endpointKey)
        let session = RemoteSession(
            profile: draft, workspace: workspace, persistent: false,
            files: SFTPController(homeURL: root, requiresAccess: false),
            screenSnapshot: { _, _ in
                [
                    .init(
                        id: CGMainDisplayID(), frame: CGRect(x: -30000, y: -30000, width: 400, height: 300),
                        backingScale: 2)
                ]
            })
        workspace.sessions.append(session)
        workspace.select(session.id)
        let desktop = session.desktop!
        precondition(desktop.displayMode == .fit, "Resize opt-in must override every stored display mode")
        let viewport = RDPViewport(desktop: desktop)
        let window = NSWindow(
            contentRect: CGRect(x: -30000, y: -30000, width: 640, height: 480), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewport
        window.orderFront(nil)
        defer {
            window.close()
            workspace.close(session)
        }
        func wait(_ seconds: TimeInterval, file: StaticString = #file, line: UInt = #line, until condition: () -> Bool)
        {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            if !condition() {
                FileHandle.standardError.write(
                    Data(
                        "FIXTURE state \(session.state) size \(desktop.desktopSize) display \(session.displayMessage)\n"
                            .utf8))
            }
            precondition(condition(), file: file, line: line)
        }
        func resize(_ width: CGFloat, _ height: CGFloat) -> RDPResizeRequest {
            window.setContentSize(CGSize(width: width, height: height))
            viewport.layoutSubtreeIfNeeded()
            viewport.layoutDesktop()
            let points = viewport.contentView.bounds.size
            return RDPResizeRequest(
                points: points, backing: desktop.convertToBacking(CGRect(origin: .zero, size: points)).size,
                backingScale: window.backingScaleFactor, retina: draft.retinaDisplay)!
        }
        if mode == "matchWindow" {
            var initial: CGSize?
            desktop.withInitialSize(width: 1600, height: 1000, matchWindow: true) { initial = $0 }
            precondition(initial == CGSize(width: 640, height: 480), "Initial size must use viewport, not preset")
            desktop.retinaDisplay = true
            desktop.withInitialSize(width: 1600, height: 1000, matchWindow: true) { initial = $0 }
            precondition(
                initial == CGSize(width: 640 * window.backingScaleFactor, height: 480 * window.backingScaleFactor),
                "Initial Retina size must scale the viewport once")
            desktop.retinaDisplay = draft.retinaDisplay
        }
        session.start(credential: ConnectionCredential(password: "fixture-password"))
        wait(8) { session.state == .connected }
        precondition(!session.initialResolution.isEmpty)
        wait(2) { session.observedDesktopSize != nil }
        precondition(session.logs.contains { $0.message.contains("initial resolution requested") })
        precondition(session.logs.contains { $0.message.contains("initial desktop received") })
        for width in stride(from: 700, through: 900, by: 2) { _ = resize(CGFloat(width), 650) }
        let newest = resize(901, 650)
        if mode == "ignored" || mode == "missing" {
            wait(9) { session.displayMessage.contains(mode == "missing" ? "not enabled" : "not confirmed") }
            precondition(desktop.desktopSize == CGSize(width: 640, height: 480) && session.state == .connected)
            print("PASS \(mode) Display Control preserves observed geometry and reports finite local-fit fallback")
        } else if mode == "restricted" {
            wait(8) { session.displayMessage.contains("does not allow") }
            precondition(desktop.desktopSize == CGSize(width: 640, height: 480) && session.state == .connected)
            let allowed = resize(600, 400)
            wait(8) { desktop.desktopSize == allowed.size && session.displayMessage.isEmpty }
            print("PASS received area caps reject oversized requests; a later allowed resize converges")
        } else {
            wait(8) {
                desktop.desktopSize == newest.size && session.displayMessage.isEmpty
                    && desktop.mailbox.snapshot()?.1.width == newest.width
                    && desktop.mailbox.snapshot()?.1.height == newest.height
            }
            if mode != "retina" {
                let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: desktop.convert(CGPoint(x: desktop.bounds.midX, y: desktop.bounds.midY), to: nil),
                    modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                    pressure: 0)!
                desktop.mouseMoved(with: event)
            }
            let wider = resize(1040, 720)
            wait(8) { desktop.desktopSize == wider.size && session.displayMessage.isEmpty }
            session.enterFullScreen()
            precondition(session.fullScreenPresented)
            session.exitFullScreen()
            let final = resize(920, 680)
            wait(8) { desktop.desktopSize == final.size && session.displayMessage.isEmpty }
            precondition(session.state == .connected && !session.fullScreenPresented)
            print(
                "PASS \(mode) viewport storm, delayed caps, graphics reactivation and full-screen exit converge on one session"
            )
        }
        precondition(session.logs.contains { $0.message.contains("RDP window resize") })
        if mode == "ignored" || mode == "missing" || mode == "restricted" {
            precondition(session.logs.contains { $0.message.hasPrefix("Display:") })
        } else {
            precondition(session.logs.contains { $0.message.contains("desktop resized by server") })
            precondition(session.logs.contains { $0.message.contains("submitted; awaiting server geometry") })
        }
        // Closing/disconnecting before a queued viewport change must not send it later.
        _ = resize(1100, 700)
        session.disconnect()
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(session.state == .disconnected && !session.fullScreenPresented)
        var drained = false
        FCRDPClient.whenAllDisconnected { DispatchQueue.main.async { drained = true } }
        wait(5) { drained }
    }
}
