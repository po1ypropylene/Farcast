import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftData

// Production sessions, adapters and lease registry against owned encrypted peers.
// Keys arrive on stdin; all stores, credentials and files are synthetic.
@main struct WireGuardSessionChecks {
    private struct Fixture: Decodable {
        let configuration: WireGuardConfiguration
        let privateKey: String
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 4 else { exit(2) }
        _ = NSApplication.shared
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let root = URL(fileURLWithPath: CommandLine.arguments[3])
        let sshPin = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let pem = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let der = Data(base64Encoded: pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined())!
        let rdpPin =
            "SHA256:" + Data(SHA256.hash(data: der)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let suite = "com.peterpo.farcast.WireGuardSessionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(
            for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let saved = try SavedWireGuard(name: "Synthetic shared tunnel", configuration: fixture.configuration)
        container.mainContext.insert(saved)
        try container.mainContext.save()
        var keysAvailable = true
        let workspace = Workspace(
            loadCredential: { id in
                if id == saved.id {
                    return keysAvailable ? ConnectionCredential(wireGuardPrivateKey: fixture.privateKey) : nil
                }
                return ConnectionCredential(password: "fixture-password")
            }, defaults: defaults)
        workspace.modelContext = container.mainContext
        defer { for session in workspace.sessions { session.disconnect() } }

        func waitUntil(_ reason: String, _ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 25
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            precondition(condition(), reason)
        }
        func helpers() -> [Int32] {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(getpid()), "-f", "FarcastWireGuard"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { preconditionFailure("Could not inspect owned helper processes") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        }
        func make(
            _ kind: RemoteProtocol, host: String = "10.111.0.1", tunnelID: UUID? = nil, trust: Bool = true
        ) -> RemoteSession {
            var draft = ConnectionDraft()
            draft.kind = kind
            draft.name = "Synthetic \(kind.rawValue)"
            draft.host = host
            draft.port = kind.defaultPort
            draft.username = "fixture"
            draft.wireGuardID = tunnelID ?? saved.id
            draft.clipboard = false
            draft.audioPlayback = false
            draft.dynamicResolution = false
            if kind == .ssh {
                let port = Int(try! String(contentsOf: root.appendingPathComponent("forward-port"), encoding: .utf8))!
                draft.forwardingRules = [SSHForwardingRule(destinationPort: port)]
            }
            if trust && kind != .vnc {
                workspace.trust.remember(kind == .ssh ? sshPin : rdpPin, for: draft.endpointKey)
            }
            let session = RemoteSession(
                profile: draft, workspace: workspace, persistent: false,
                files: SFTPController(homeURL: root, requiresAccess: false))
            workspace.sessions.append(session)
            session.sshMode = .files
            session.start(credential: ConnectionCredential(password: "fixture-password"))
            return session
        }
        func listFiles(_ session: RemoteSession) async throws {
            session.files.refreshRemote()
            try await waitUntil("SFTP did not remain usable through the shared tunnel") {
                session.state == .connected && !session.files.busy && !session.files.remoteFiles.isEmpty
            }
        }
        func checkForwarding(_ session: RemoteSession) async throws {
            let rule = session.profile.forwardingRules[0]
            try await waitUntil("SSH forwarding did not start over WireGuard") {
                session.forwarding.statuses[rule.id]?.state == "listening"
            }
            let port = session.forwarding.statuses[rule.id]!.port
            let valid = await Task.detached {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { return false }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                address.sin_port = UInt16(port).bigEndian
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                guard connected else { return false }
                let data = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
                var sent = 0
                while sent < data.count {
                    let count = data.withUnsafeBytes {
                        send(fd, $0.baseAddress!.advanced(by: sent), data.count - sent, 0)
                    }
                    if count <= 0 { return false }
                    sent += count
                }
                shutdown(fd, SHUT_WR)
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 32768)
                while true {
                    let count = recv(fd, &buffer, buffer.count, 0)
                    if count < 0 { return false }
                    if count == 0 { break }
                    result.append(contentsOf: buffer.prefix(count))
                }
                return result == data + Data("TAIL".utf8)
            }.value
            precondition(valid, "Forwarded bytes/half-close tail did not cross the encrypted SSH transport")
        }

        let missing = make(.ssh, tunnelID: UUID())
        precondition(missing.state == .failed && missing.message == WireGuardError.unavailable.localizedDescription)
        precondition(missing.vpnState == .failed)
        keysAvailable = false
        let noKeys = make(.ssh)
        precondition(noKeys.state == .failed && noKeys.message == WireGuardError.missingKeys.localizedDescription)
        let vncNoKeys = make(.vnc)
        precondition(vncNoKeys.state == .failed && vncNoKeys.message == WireGuardError.missingKeys.localizedDescription)
        keysAvailable = true
        let vncMissing = make(.vnc, tunnelID: UUID())
        precondition(
            vncMissing.state == .failed && vncMissing.message == WireGuardError.unavailable.localizedDescription)
        precondition(helpers().isEmpty)
        print("PASS SSH refuses missing WireGuard profiles and keys before protocol startup")

        let first = make(.ssh)
        precondition(first.vpnState == .connecting)
        let second = make(.ssh)
        let desktop = make(.rdp)
        let vnc = make(.vnc)
        try await waitUntil("Mixed encrypted sessions did not connect") {
            [first, second, desktop, vnc].allSatisfy { $0.state == .connected }
        }
        precondition([first, second, desktop, vnc].allSatisfy { $0.vpnState == .connected })
        try await listFiles(first)
        try await listFiles(second)
        try await checkForwarding(first)
        try await checkForwarding(second)
        print("PASS SSH TCP forwarding byte equality and half-close use the shared WireGuard SSH transport")
        for session in [first, second, desktop, vnc] {
            precondition(session.logs.contains { $0.message.contains("VPN: establishing") })
            precondition(session.logs.contains { $0.message.contains("VPN: destination lease ready") })
        }
        precondition(first.terminalAvailable && second.terminalAvailable)
        first.terminal?.sendBytes?(Data("encrypted-terminal-check\n".utf8))
        try await waitUntil("SSH terminal input/output did not cross the encrypted tunnel") {
            guard let data = first.terminal?.view.getBufferAsData() else { return false }
            return String(decoding: data, as: UTF8.self).contains("INPUT:encrypted-terminal-check")
        }
        precondition(helpers().count == 1)
        precondition(workspace.prompts.isEmpty)
        precondition(workspace.trust.fingerprint(for: first.profile.endpointKey) == sshPin)
        precondition(workspace.trust.fingerprint(for: "ssh|127.0.0.1|22") == nil)
        print("PASS two SSH/SFTP sessions, RDP and VNC share exactly one helper; original endpoint trust is retained")

        for host in ["127.0.0.1", "unresolved.invalid"] {
            let refused = make(.ssh, host: host)
            try await waitUntil("Unsafe tunneled destination did not fail closed") { refused.state == .failed }
            precondition(refused.message.contains(host == "127.0.0.1" ? "routes" : "DNS servers"))
            precondition(!refused.credentialsRejected && workspace.prompts.isEmpty)
            precondition([first, second, desktop, vnc].allSatisfy { $0.state == .connected })
        }
        workspace.trust.forget(first.profile.endpointKey)
        let rejected = make(.ssh, trust: false)
        try await waitUntil("Tunneled SSH did not verify its host key") {
            workspace.prompts.contains { $0.sessionID == rejected.id }
        }
        let prompt = workspace.prompts.first { $0.sessionID == rejected.id }!
        precondition(prompt.kind == .trust && prompt.fingerprint == sshPin)
        workspace.answer(prompt, value: nil)
        try await waitUntil("Rejected host key did not fail SSH") { rejected.state == .failed }
        precondition(rejected.vpnState == .disconnected)
        workspace.trust.remember(sshPin, for: first.profile.endpointKey)
        precondition(helpers().count == 1)
        print("PASS tunneled SSH DNS/route refusal and host-key rejection leave other protocols connected")

        for host in ["127.0.0.1", "unresolved.invalid"] {
            let refused = make(.vnc, host: host)
            try await waitUntil("Unsafe tunneled VNC destination did not fail closed") { refused.state == .failed }
            precondition(refused.message.contains(host == "127.0.0.1" ? "routes" : "DNS servers"))
            precondition([first, second, desktop, vnc].allSatisfy { $0.state == .connected })
        }
        try await waitUntil("VNC did not render through WireGuard") { vnc.desktop?.mailbox.snapshot()?.1.width == 40 }
        vnc.typeVNCText("Encrypted 中😀")
        try await waitUntil("VNC typing through WireGuard did not finish") { !vnc.vncTyping }
        vnc.controlAltDelete()
        try await Task.sleep(for: .milliseconds(100))
        vnc.disconnect()
        let eventsFile = root.deletingLastPathComponent().appendingPathComponent("vnc/events-1.json")
        try await waitUntil("VNC peer did not retire its socket") {
            FileManager.default.fileExists(atPath: eventsFile.path)
        }
        let events = try JSONSerialization.jsonObject(with: Data(contentsOf: eventsFile)) as! [[Any]]
        let keys = events.filter { ($0.first as? String) == "key" }
        precondition(keys.contains { ($0[1] as? Int) == 1 && ($0[2] as? UInt32) == 0x0100_4E2D })
        precondition(keys.contains { ($0[1] as? Int) == 1 && ($0[2] as? UInt32) == 0x0101_F600 })
        precondition(
            keys.suffix(6).map { ($0[1] as! Int, $0[2] as! Int) }.elementsEqual(
                [(1, 0xFFE3), (1, 0xFFE9), (1, 0xFFFF), (0, 0xFFFF), (0, 0xFFE9), (0, 0xFFE3)], by: ==))
        try await listFiles(second)
        precondition(desktop.state == .connected && helpers().count == 1)
        let replacementVNC = make(.vnc)
        try await waitUntil("VNC did not reacquire its independent lease") { replacementVNC.state == .connected }
        print("PASS VNC encrypted frames/input, DNS/route refusal and independent reconnect")

        first.disconnect()
        precondition(first.vpnState == .disconnected && second.vpnState == .connected)
        try await listFiles(second)
        precondition(desktop.state == .connected && (helpers().count) == 1)
        desktop.disconnect()
        try await listFiles(second)
        precondition((helpers().count) == 1)
        workspace.reconnect(second)
        let reconnected = workspace.sessions.first { $0.profile.id == second.profile.id && $0 !== second }!
        // Report only the allowlisted synthetic session state if startup fails.
        try await waitUntil("SSH reconnect did not finish startup") {
            reconnected.state == .connected || reconnected.state == .failed || !workspace.prompts.isEmpty
        }
        if reconnected.state != .connected {
            FileHandle.standardError.write(
                Data(
                    "Synthetic SSH reconnect state: \(reconnected.state.rawValue); prompt count: \(workspace.prompts.count); message: \(reconnected.message)\n"
                        .utf8))
        }
        try await waitUntil("SSH reconnect did not reacquire the tunnel") { reconnected.state == .connected }
        try await listFiles(reconnected)
        try await checkForwarding(reconnected)
        let replacementDesktop = make(.rdp)
        try await waitUntil("RDP did not join the reconnected SSH tunnel") { replacementDesktop.state == .connected }
        precondition(helpers().count == 1)
        print("PASS independent SSH/RDP disconnect and SSH reconnect preserve shared-tunnel service")

        let children = helpers()
        precondition(children.count == 1)
        precondition(kill(children[0], SIGTERM) == 0)
        try await waitUntil("Helper exit did not stop SSH/VNC and trigger RDP recovery") {
            reconnected.state == .failed && replacementVNC.state == .failed
                && replacementDesktop.logs.contains { $0.message.hasPrefix("Connection lost. Reconnecting in ") }
        }
        precondition(!reconnected.message.isEmpty && !replacementDesktop.message.isEmpty)
        // Native transport loss can release a lease before the helper-exit callback arrives.
        precondition([reconnected, replacementVNC].allSatisfy { [.failed, .disconnected].contains($0.vpnState) })
        precondition(reconnected.forwarding.statuses.values.allSatisfy { $0.state == "stopped" })
        precondition(workspace.prompts.isEmpty)
        try await waitUntil("RDP did not automatically reacquire its WireGuard lease") {
            replacementDesktop.state == .connected
        }
        precondition(workspace.sessions.contains { $0 === replacementDesktop })
        precondition(replacementDesktop.vpnState == .connected)
        precondition(helpers().count == 1 && workspace.prompts.isEmpty)
        print("PASS shared helper loss stops SSH/VNC and automatically reconnects RDP in its existing session")
        let restartedSSH = make(.ssh)
        let restartedRDP = make(.rdp)
        let restartedVNC = make(.vnc)
        try await waitUntil("Sessions did not restart after shared helper failure") {
            restartedSSH.state == .connected && restartedRDP.state == .connected && restartedVNC.state == .connected
        }
        precondition(helpers().count == 1)
        await withCheckedContinuation { continuation in workspace.shutdown { continuation.resume() } }
        precondition(helpers().isEmpty)
        precondition(workspace.sessions.allSatisfy { $0.state == .disconnected })
        precondition(workspace.sessions.allSatisfy { $0.vpnState == .disconnected })
        print(
            "PASS shared helper failure reaches SSH, RDP and VNC, recovery works, and shutdown drains all workers/helpers"
        )
    }
}
