import AppKit
import CryptoKit
import Foundation

private final class ControlledRDPClient: FCRDPClient {
    var healthy = true
    var interrupted = false
    var cancelled = false
    override var responsive: Bool { healthy }
    override func interruptStalledConnection() { interrupted = true }
    override func disconnect() { cancelled = true }
    override func connectHost(
        _ host: String, port: Int, username: String, domain: String, password: String,
        width: Int, height: Int, scale: Int, clipboard: Bool, audioPlayback: Bool
    ) {
        onStatus("connecting", "Connecting to fixture")
    }
    func connected() { onStatus("connected", "Fixture connected") }
    func lost(retryable: Bool = true) {
        onStatus("failed", "Fixture transport lost")
        onStopped?(retryable)
    }
}

@main struct RDPReconnectSessionChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite = "com.peterpo.farcast.RDPReconnectTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(loadCredential: { _ in nil }, defaults: defaults)
        var profile = ConnectionDraft()
        profile.kind = .rdp
        profile.host = "127.0.0.1"
        profile.clipboard = false
        profile.audioPlayback = false
        var clients: [ControlledRDPClient] = []
        func makeSession() -> RemoteSession {
            let session = RemoteSession(
                profile: profile, workspace: workspace, persistent: false,
                files: SFTPController(homeURL: URL(fileURLWithPath: CommandLine.arguments[1]), requiresAccess: false),
                makeRDPClient: {
                    let client = ControlledRDPClient()
                    clients.append(client)
                    return client
                })
            workspace.sessions.append(session)
            session.start(credential: ConnectionCredential(password: "synthetic"))
            return session
        }
        func pump(_ seconds: TimeInterval = 0.05) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func wait(_ seconds: TimeInterval = 3, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { pump(0.01) }
            precondition(condition())
        }
        let session = makeSession()
        let first = clients.last!
        let experimental = UserDefaults.standard.bool(forKey: "experimentalRDP")
        precondition(session.experimentalRDPEnabled == experimental)
        precondition(first.experimentalGraphics == experimental)
        precondition(first.inputWakeEnabled == experimental)
        precondition((first.onFrameRegion != nil) == experimental)
        print("PASS RDP app preference configures graphics, input wakeups and dirty patches: \(experimental)")
        first.connected()
        wait { session.state == .connected }
        precondition(session.desktop?.inputEnabled == true)
        first.onStatus("failed", "Lost before cleanup")
        pump()
        precondition(session.state == .failed && session.desktop?.inputEnabled == false)
        pump(2.2)
        precondition(clients.count == 1, "Must await native cleanup before replacing a client")
        precondition(session.latestFailure == "Lost before cleanup")
        first.onStopped?(true)
        wait { session.state == .reconnecting }
        precondition(session.message.contains("attempt 1 of 3"))
        precondition(session.latestFailure == "Lost before cleanup", "Recovery must preserve the actual failure")
        let logCount = session.logs.count
        first.onDesktopSize?(333, 222)
        first.connected()  // Old generation must not paint the session as connected.
        pump()
        precondition(session.state == .reconnecting)
        precondition(session.logs.count == logCount && session.observedDesktopSize == nil)
        wait { clients.count == 2 }
        clients.last!.lost()
        wait { session.state == .reconnecting && session.message.contains("attempt 2 of 3") }
        wait(6) { clients.count == 3 }
        clients.last!.connected()
        wait { session.state == .connected }
        clients.last!.lost()
        wait { session.state == .reconnecting && session.message.contains("attempt 3 of 3") }
        wait(11) { clients.count == 4 }
        clients.last!.lost()
        wait { session.state == .failed && session.message.contains("after 3 attempts") }
        pump(2.2)
        precondition(clients.count == 4 && workspace.sessions.first === session)
        print("PASS same-tab retry limit, flapping budget, teardown ordering and stale status rejection")

        let cancelled = makeSession()
        clients.last!.connected()
        wait { cancelled.state == .connected }
        clients.last!.lost()
        wait { cancelled.state == .reconnecting }
        cancelled.disconnect()
        precondition(cancelled.latestFailure == "Fixture transport lost")
        let count = clients.count
        pump(2.2)
        precondition(clients.count == count && cancelled.state == .disconnected)
        print("PASS Cancel stops scheduled reconnection")

        let rejected = makeSession()
        clients.last!.connected()
        wait { rejected.state == .connected }
        clients.last!.lost(retryable: false)
        wait { rejected.state == .failed }
        let rejectedCount = clients.count
        pump(2.2)
        precondition(clients.count == rejectedCount)
        print("PASS nonretryable authentication/trust/server termination stays stopped")

        let stale = makeSession()
        let stalledClient = clients.last!
        stalledClient.connected()
        wait { stale.state == .connected }
        stalledClient.healthy = false
        wait(6) { stale.state == .stale }
        precondition(stalledClient.interrupted && stale.desktop?.inputEnabled == false)
        stale.disconnect()
        stalledClient.onStopped?(true)
        pump(2.2)
        precondition(stale.state == .disconnected && stalledClient.cancelled)
        print("PASS stale worker disables input, interrupts transport and honors Cancel before cleanup")
        // Sleep notifications must invalidate the visible connected state before
        // native cleanup, independently of worker health or the reconnect setting.
        let sleeping = makeSession()
        let sleepingClient = clients.last!
        sleepingClient.connected()
        wait { sleeping.state == .connected }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        precondition(sleeping.state == .disconnected && sleeping.connectedAt == nil)
        precondition(sleeping.desktop?.inputEnabled == false && sleepingClient.cancelled)
        sleepingClient.connected()
        pump()
        precondition(sleeping.state == .disconnected)
        let sleepCount = clients.count
        sleepingClient.onStopped?(false)
        pump()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        pump(2.2)
        precondition(clients.count == sleepCount && sleeping.state == .disconnected)
        print("PASS default sleep disconnect stops uptime/input and rejects late Connected without reconnecting")

        defaults.set(true, forKey: "reconnectRDPAfterWake")
        let waking = makeSession()
        let wakingClient = clients.last!
        wakingClient.connected()
        wait { waking.state == .connected }
        waking.desktop?.submit(Data(repeating: 127, count: 16), width: 2, height: 2, stride: 8)
        workspace.systemWillSleep()
        workspace.systemDidWake()
        let wakeCount = clients.count
        pump(2.2)
        precondition(clients.count == wakeCount && waking.state == .disconnected)
        wakingClient.onStopped?(false)
        wait { waking.state == .reconnecting }
        precondition(waking.desktop?.mailbox.snapshot() == nil, "Old desktop must not survive wake recovery")
        wakingClient.connected()
        pump()
        precondition(waking.state == .reconnecting)
        wait { clients.count == wakeCount + 1 }
        clients.last!.connected()
        wait { waking.state == .connected }
        precondition(workspace.sessions.contains { $0 === waking })
        print("PASS opt-in wake reconnect waits for cleanup and retains the session tab")

        workspace.systemWillSleep()
        clients.last!.onStopped?(false)
        pump()
        workspace.systemDidWake()
        precondition(waking.state == .reconnecting)
        let cancelWakeCount = clients.count
        waking.disconnect()
        pump(2.2)
        precondition(clients.count == cancelWakeCount && waking.state == .disconnected)
        print("PASS Cancel prevents wake reconnect after cleanup completed during sleep")

        let missed = makeSession()
        clients.last!.connected()
        wait { missed.state == .connected }
        workspace.systemDidWake()
        precondition(missed.state == .disconnected && missed.connectedAt == nil)
        missed.disconnect()
        defaults.set(false, forKey: "reconnectRDPAfterWake")
        print("PASS missed willSleep still retires the pre-wake connection")

        // Exercise the full production path against an owned TLS peer after the
        // controlled callback cases. The native worker is interrupted as if stale.
        profile.port = Int(CommandLine.arguments[2])!
        profile.username = "fixture"
        let pem = try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        let body = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        let pin =
            "SHA256:"
            + Data(SHA256.hash(data: Data(base64Encoded: body)!))
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        workspace.trust.remember(pin, for: profile.endpointKey)
        var nativeClients: [FCRDPClient] = []
        let live = RemoteSession(
            profile: profile, workspace: workspace, persistent: false,
            files: SFTPController(homeURL: URL(fileURLWithPath: CommandLine.arguments[1]), requiresAccess: false),
            makeRDPClient: {
                let client = FCRDPClient()
                nativeClients.append(client)
                return client
            })
        workspace.sessions.append(live)
        live.start(credential: ConnectionCredential(password: "synthetic"))
        wait(10) { live.state == .connected && live.desktop?.mailbox.snapshot() != nil }
        nativeClients[0].interruptStalledConnection()
        wait { live.state == .reconnecting }
        wait(12) { live.state == .connected && nativeClients.count == 2 }
        precondition(workspace.sessions.last === live && live.desktop?.inputEnabled == true)
        print("PASS native TLS session reauthenticates in the same tab after interrupted transport cleanup")
        defaults.set(true, forKey: "reconnectRDPAfterWake")
        workspace.systemWillSleep()
        precondition(live.state == .disconnected && live.connectedAt == nil && live.desktop?.inputEnabled == false)
        workspace.systemDidWake()
        wait(15) { live.state == .connected && nativeClients.count == 3 && live.desktop?.mailbox.snapshot() != nil }
        precondition(workspace.sessions.last === live && live.desktop?.inputEnabled == true)
        print("PASS sleep cancellation closes the native TLS worker and wake reconnect receives a fresh desktop")
        for session in workspace.sessions { session.disconnect() }
        var drained = false
        FCRDPClient.whenAllDisconnected { DispatchQueue.main.async { drained = true } }
        wait(10) { drained }
    }
}
