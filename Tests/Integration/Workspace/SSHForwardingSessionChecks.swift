import AppKit
import Foundation
import SwiftData
import SwiftUI

@main struct SSHForwardingSessionChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let suite = "com.peterpo.farcast.forwarding-session-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(
            loadCredential: { _ in ConnectionCredential(password: "fixture-password") }, defaults: defaults)
        var draft = ConnectionDraft()
        draft.host = "127.0.0.1"
        draft.port = Int(CommandLine.arguments[1])!
        draft.username = "fixture"
        draft.forwardingRules = [SSHForwardingRule(kind: .socks)]
        let rule = draft.forwardingRules[0]
        workspace.trust.remember(
            try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8), for: draft.endpointKey)
        let first = RemoteSession(
            profile: draft, workspace: workspace, persistent: false,
            files: SFTPController(homeURL: URL(fileURLWithPath: CommandLine.arguments[3]), requiresAccess: false))
        workspace.sessions.append(first)
        first.start(credential: ConnectionCredential(password: "fixture-password"))
        func wait(_ reason: String, _ condition: () -> Bool) async throws {
            for _ in 0..<1000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            precondition(condition(), reason)
        }
        try await wait("Forwarding-only session did not start") {
            first.state == .connected && first.forwarding.statuses[rule.id]?.state == "listening"
        }
        precondition(!first.terminalAvailable && !first.filesAvailable && first.sshMode == .tunnels)
        precondition(!first.files.busy && workspace.prompts.isEmpty)
        print("PASS production forwarding-only capabilities select Tunnels and leave Files idle")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        let container = try ModelContainer(
            for: SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        window.contentView = NSHostingView(
            rootView: SSHForwardingView(controller: first.forwarding, connected: true).modelContainer(container))
        window.contentView?.layoutSubtreeIfNeeded()
        precondition(first.forwarding.statuses[rule.id]!.port > 0)
        first.forwarding.stop(rule)
        try await wait("Controller Stop did not finish") { first.forwarding.statuses[rule.id]?.state == "stopped" }
        first.forwarding.start(rule)
        try await wait("Controller Start did not finish") { first.forwarding.statuses[rule.id]?.state == "listening" }
        print("PASS native tunnel view and controller Stop/Start use actual dynamic ports")
        var added = SSHForwardingRule(kind: .socks)
        try first.forwarding.apply(added, start: true)
        try await wait("Live add did not start") { first.forwarding.statuses[added.id]?.state == "listening" }
        added.bindAddress = "::1"
        try first.forwarding.apply(added, start: true)
        try await wait("Live edit did not start") { first.forwarding.statuses[added.id]?.state == "listening" }
        try first.forwarding.remove(added)
        try await wait("Live removal did not finish") { !first.forwarding.rules.contains { $0.id == added.id } }
        precondition(first.state == .connected && first.forwarding.statuses[rule.id]?.state == "listening")
        workspace.requestDisconnect(first)
        precondition(workspace.pendingSessionAction != nil && first.state == .connected)
        workspace.pendingSessionAction = nil
        print("PASS live add/edit/remove preserve SSH and active tunnels require interruption confirmation")
        workspace.reconnect(first)
        let replacement = workspace.sessions.first { $0 !== first }!
        try await wait("Forwarding-only reconnect did not restart rules") {
            replacement.state == .connected && replacement.forwarding.statuses[rule.id]?.state == "listening"
        }
        precondition(replacement.sshMode == .tunnels && !replacement.filesAvailable)
        replacement.disconnect()
        replacement.forwarding.receive(
            id: rule.id.uuidString, state: "listening", port: 12345, connections: 3, message: "")
        precondition(replacement.forwarding.statuses[rule.id]?.state == "stopped")
        print("PASS reconnect restarts rules and disconnect rejects stale controller events")
        await withCheckedContinuation { continuation in FCSSHClient.whenAllDisconnected { continuation.resume() } }
        print("PASS production forwarding-only workers drained")
    }
}
