import AppKit
import CryptoKit
import Foundation

@main struct RDPSessionDisplayChecks {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let port = Int(CommandLine.arguments[1])!
        let pem = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        let der = Data(base64Encoded: body)!
        let pin = "SHA256:" + Data(SHA256.hash(data: der)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let suite = "com.peterpo.farcast.RDPDisplaySessionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(loadCredential: { _ in nil }, defaults: defaults)
        let single: [RDPDisplayScreen] = [
            .init(
                id: CGMainDisplayID(), frame: CGRect(x: -30000, y: -30000, width: 400, height: 300),
                backingScale: 2, physicalSize: CGSize(width: 300, height: 200))
        ]
        let all: [RDPDisplayScreen] = [
            .init(
                id: CGMainDisplayID(), frame: CGRect(x: -30000, y: -30000, width: 640, height: 360), backingScale: 2,
                physicalSize: CGSize(width: 300, height: 200)),
            .init(
                id: 999, frame: CGRect(x: -30800, y: -30060, width: 800, height: 600), backingScale: 1,
                physicalSize: CGSize(width: 300, height: 200)),
        ]
        func make(allMonitors: Bool, launchFullScreen: Bool = true) -> RemoteSession {
            var draft = ConnectionDraft()
            draft.host = "127.0.0.1"
            draft.port = port
            draft.username = "fixture"
            draft.kind = .rdp
            draft.launchFullScreen = launchFullScreen
            draft.useAllMonitors = allMonitors
            draft.retinaDisplay = true
            draft.dynamicResolution = false
            draft.clipboard = false
            draft.audioPlayback = false
            if !launchFullScreen {
                draft.retinaDisplay = false
                draft.desktopWidth = 640
                draft.desktopHeight = 480
            }
            workspace.trust.remember(pin, for: draft.endpointKey)
            let session = RemoteSession(
                profile: draft, workspace: workspace, persistent: false,
                files: SFTPController(homeURL: root, requiresAccess: false),
                screenSnapshot: { useAll, _ in useAll ? all : single })
            workspace.sessions.append(session)
            workspace.select(session.id)
            session.start(credential: ConnectionCredential(password: "fixture-password"))
            return session
        }
        func wait(_ seconds: TimeInterval, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline && !condition() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition())
        }
        let first = make(allMonitors: false)
        wait(8) { first.state == .connected && first.fullScreenPresented }
        precondition(first.desktop?.desktopSize == CGSize(width: 800, height: 600))
        precondition(first.desktop!.isPaused && workspace.activeSession === first)
        first.exitFullScreen()
        precondition(first.state == .connected && !first.fullScreenPresented && !first.desktop!.isPaused)
        for _ in 0..<3 {
            first.enterFullScreen()
            precondition(first.state == .connected && first.fullScreenPresented && first.desktop!.isPaused)
            first.enterFullScreen()
            precondition(app.windows.filter { $0.title == "Farcast remote desktop" && $0.isVisible }.count == 1)
            first.exitFullScreen()
            precondition(first.state == .connected && !first.fullScreenPresented && !first.desktop!.isPaused)
        }
        workspace.close(first)
        first.enterFullScreen()
        precondition(!first.fullScreenPresented)
        print(
            "PASS production Retina session repeatedly exits and re-enters full screen without reconnecting or duplicate windows"
        )
        let windowed = make(allMonitors: false, launchFullScreen: false)
        wait(8) { windowed.state == .connected && windowed.desktop?.desktopSize == CGSize(width: 640, height: 480) }
        precondition(!windowed.fullScreenPresented)
        windowed.enterFullScreen()
        precondition(windowed.fullScreenPresented && windowed.desktop!.isPaused)
        let surface = app.windows.first { $0.title == "Farcast remote desktop" && $0.isVisible }!.contentView!.subviews
            .compactMap { $0 as? RDPDesktopView }.first!
        precondition(surface.expectedDesktopSize == CGSize(width: 640, height: 480))
        precondition(surface.sourceRect == CGRect(x: 0, y: 0, width: 640, height: 480))
        windowed.exitFullScreen()
        precondition(windowed.state == .connected && !windowed.desktop!.isPaused)
        workspace.close(windowed)
        print("PASS windowed startup enters full screen using the existing negotiated desktop dimensions")
        let second = make(allMonitors: true)
        wait(10) { second.state == .connected && second.displayMessage.contains("did not confirm") }
        precondition(!second.fullScreenPresented && second.desktop?.desktopSize == CGSize(width: 2080, height: 720))
        precondition(!second.desktop!.isPaused && workspace.prompts.isEmpty)
        second.enterFullScreen()
        precondition(
            !second.fullScreenPresented && second.state == .connected && second.displayMessage.contains("not confirmed")
        )
        workspace.close(second)
        print(
            "PASS missing server monitor confirmation preserves an authenticated aggregate desktop with a finite notice"
        )
        let third = make(allMonitors: true)
        wait(8) { third.state == .connected }
        third.disconnect()
        let deadline = Date().addingTimeInterval(5.2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(third.state == .disconnected && !third.fullScreenPresented && workspace.prompts.isEmpty)
        precondition(!app.windows.contains { $0.title == "Farcast remote desktop" && $0.isVisible })
        workspace.close(third)
        var drained = false
        FCRDPClient.whenAllDisconnected { DispatchQueue.main.async { drained = true } }
        wait(5) { drained }
        print("PASS disconnect cancels pending presentation/observation and drains the single RDP transport")
    }
}
