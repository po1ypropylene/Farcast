import AppKit
import CryptoKit
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
            draft.port = kind == .ssh ? 22 : 3389
            draft.username = "fixture"
            draft.wireGuardID = tunnelID ?? saved.id
            draft.clipboard = false
            draft.audioPlayback = false
            draft.dynamicResolution = false
            if trust { workspace.trust.remember(kind == .ssh ? sshPin : rdpPin, for: draft.endpointKey) }
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

        let missing = make(.ssh, tunnelID: UUID())
        precondition(missing.state == .failed && missing.message == WireGuardError.unavailable.localizedDescription)
        keysAvailable = false
        let noKeys = make(.ssh)
        precondition(noKeys.state == .failed && noKeys.message == WireGuardError.missingKeys.localizedDescription)
        keysAvailable = true
        precondition(helpers().isEmpty)
        print("PASS SSH refuses missing WireGuard profiles and keys before protocol startup")

        let first = make(.ssh)
        let second = make(.ssh)
        let desktop = make(.rdp)
        try await waitUntil("Mixed encrypted sessions did not connect") {
            [first, second, desktop].allSatisfy { $0.state == .connected }
        }
        try await listFiles(first)
        try await listFiles(second)
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
        print("PASS two SSH/SFTP sessions and RDP share exactly one helper; original endpoint trust is retained")

        for host in ["127.0.0.1", "unresolved.invalid"] {
            let refused = make(.ssh, host: host)
            try await waitUntil("Unsafe tunneled destination did not fail closed") { refused.state == .failed }
            precondition(refused.message.contains(host == "127.0.0.1" ? "AllowedIPs" : "DNS servers"))
            precondition(!refused.credentialsRejected && workspace.prompts.isEmpty)
            precondition([first, second, desktop].allSatisfy { $0.state == .connected })
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
        workspace.trust.remember(sshPin, for: first.profile.endpointKey)
        precondition(helpers().count == 1)
        print("PASS tunneled SSH DNS/route refusal and host-key rejection leave other protocols connected")

        first.disconnect()
        try await listFiles(second)
        precondition(desktop.state == .connected && (helpers().count) == 1)
        desktop.disconnect()
        try await listFiles(second)
        precondition((helpers().count) == 1)
        workspace.reconnect(second)
        let reconnected = workspace.sessions.first { $0.profile.id == second.profile.id && $0 !== second }!
        try await waitUntil("SSH reconnect did not reacquire the tunnel") { reconnected.state == .connected }
        try await listFiles(reconnected)
        let replacementDesktop = make(.rdp)
        try await waitUntil("RDP did not join the reconnected SSH tunnel") { replacementDesktop.state == .connected }
        precondition(helpers().count == 1)
        print("PASS independent SSH/RDP disconnect and SSH reconnect preserve shared-tunnel service")

        let children = helpers()
        precondition(children.count == 1)
        precondition(kill(children[0], SIGTERM) == 0)
        try await waitUntil("Helper exit did not fail every mixed-protocol lease") {
            reconnected.state == .failed && replacementDesktop.state == .failed
        }
        precondition(!reconnected.message.isEmpty && !replacementDesktop.message.isEmpty)
        precondition(workspace.prompts.isEmpty)
        let restartedSSH = make(.ssh)
        let restartedRDP = make(.rdp)
        try await waitUntil("Sessions did not restart after shared helper failure") {
            restartedSSH.state == .connected && restartedRDP.state == .connected
        }
        precondition(helpers().count == 1)
        await withCheckedContinuation { continuation in workspace.shutdown { continuation.resume() } }
        precondition(helpers().isEmpty)
        precondition(workspace.sessions.allSatisfy { $0.state == .disconnected })
        print("PASS shared helper failure reaches SSH and RDP, recovery works, and shutdown drains all workers/helpers")
    }
}
