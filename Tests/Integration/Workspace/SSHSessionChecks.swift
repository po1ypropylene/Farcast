import AppKit
import Foundation

// Uses the production workspace/session/adapters with synthetic credentials and
// disposable preferences. Never opens the user's database or credential stores.
@main struct SSHSessionChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3,
            let port = Int(CommandLine.arguments[1])
        else { exit(2) }
        _ = NSApplication.shared
        let suite = "com.peterpo.farcast.SSHSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var lookups = 0
        let workspace = Workspace(
            loadCredential: { _ in
                lookups += 1
                var credential = ConnectionCredential()
                credential.password = "wrong"
                return credential
            }, defaults: defaults)
        defer { for session in workspace.sessions { session.disconnect() } }
        var draft = ConnectionDraft()
        draft.name = "Synthetic file-only account"
        draft.host = "127.0.0.1"
        draft.port = port
        draft.username = "fixture"
        let pin = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        workspace.trust.remember(pin, for: draft.endpointKey)

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(condition(), "Synthetic session check timed out.")
        }

        workspace.connect(draft)
        let rejected = workspace.sessions[0]
        try await waitUntil { rejected.state == .failed }
        precondition(rejected.credentialsRejected && lookups == 1 && workspace.prompts.isEmpty)

        workspace.reconnect(rejected)
        let retry = workspace.sessions[0]
        precondition(retry !== rejected && retry.profile.id == draft.id && retry.persistent)
        precondition(workspace.selectedSessionID == retry.id && lookups == 1)
        guard let prompt = workspace.prompts.first else {
            preconditionFailure("Retry did not request fresh credentials.")
        }
        precondition(prompt.kind == .credentials && prompt.sessionID == retry.id)
        var fresh = ConnectionCredential()
        fresh.password = "fixture-password"
        workspace.answer(prompt, value: String(decoding: try JSONEncoder().encode(fresh), as: UTF8.self))
        try await waitUntil {
            retry.state == .connected && !retry.terminalAvailable && !retry.files.busy
                && !retry.files.remoteFiles.isEmpty
        }
        precondition(retry.sshMode == .files && !retry.credentialsRejected && lookups == 1)
        precondition(workspace.prompts.isEmpty && rejected.state == .disconnected)
        print("PASS production SSH credential rejection → fresh prompt → file-only SFTP listing")

        var routed = draft
        routed.id = UUID()
        routed.wireGuardID = UUID()  // Deliberately unavailable: direct startup must never resolve it.
        workspace.connect(routed, credential: fresh, bypassVPN: true)
        let direct = workspace.sessions.last!
        try await waitUntil { direct.state == .connected && !direct.files.busy && !direct.files.remoteFiles.isEmpty }
        precondition(direct.profile.wireGuardID == nil && direct.bypassVPN && lookups == 1)
        precondition(direct.vpnState == .waiting && workspace.prompts.isEmpty)
        workspace.close(direct)
        print("PASS production Connect Direct bypasses unavailable VPN and authenticates SSH/SFTP directly")

        // Closing removes the session from the workspace before its worker exits.
        workspace.close(retry)
        let pending = RemoteSession(profile: draft, workspace: workspace, persistent: false)
        workspace.sessions.append(pending)
        pending.askForCredentials()
        precondition(!workspace.prompts.isEmpty)
        await withCheckedContinuation { continuation in
            workspace.shutdown { continuation.resume() }
        }
        precondition(workspace.isShuttingDown && workspace.prompts.isEmpty)
        precondition(retry.state == .disconnected && workspace.sessions.allSatisfy { $0.state == .disconnected })
        print("PASS production shutdown drains a closed SSH/SFTP worker and cancels credential prompts")
    }
}
