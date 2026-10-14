import Combine
import Foundation
import SwiftUI

struct SSHForwardingStatus {
    var state = "stopped"
    var port = 0
    var connections = 0
    var message = ""
    var title: String {
        switch state {
        case "failed": return "Error"
        case "starting": return "Starting"
        case "stopping": return "Stopping"
        case "listening": return "Listening"
        default: return "Stopped"
        }
    }
    var color: Color { state == "failed" ? .red : state == "listening" ? .green : running ? .orange : .secondary }
    var running: Bool { state == "starting" || state == "listening" || state == "stopping" }
}

@MainActor final class SSHForwardingController: ObservableObject {
    @Published private(set) var rules: [SSHForwardingRule]
    var hasActiveTunnels: Bool { statuses.values.contains { $0.running } }
    @Published private(set) var statuses: [UUID: SSHForwardingStatus] = [:]
    private weak var client: FCSSHClient?
    private var pendingRemovals: Set<UUID> = []
    init(rules: [SSHForwardingRule]) { self.rules = rules }
    func attach(_ client: FCSSHClient) {
        self.client = client
        statuses = Dictionary(
            rules.map { ($0.id, SSHForwardingStatus(state: $0.enabled ? "starting" : "stopped")) },
            uniquingKeysWith: { _, new in new })
    }
    func receive(id: String, state: String, port: Int, connections: Int, message: String) {
        guard client != nil, let id = UUID(uuidString: id), rules.contains(where: { $0.id == id }) else { return }
        if state == "removed" {
            rules.removeAll { $0.id == id }
            statuses.removeValue(forKey: id)
            pendingRemovals.remove(id)
        } else {
            statuses[id] = SSHForwardingStatus(
                state: pendingRemovals.contains(id) ? "stopping" : state, port: port, connections: connections,
                message: message)
        }
    }
    func start(_ rule: SSHForwardingRule) {
        guard let client, !(statuses[rule.id]?.running ?? false) else { return }
        statuses[rule.id] = SSHForwardingStatus(state: "starting")
        client.startForwarding(rule.id.uuidString)
    }
    func stop(_ rule: SSHForwardingRule) {
        guard let client, statuses[rule.id]?.running == true, statuses[rule.id]?.state != "stopping" else { return }
        statuses[rule.id]?.state = "stopping"
        client.stopForwarding(rule.id.uuidString)
    }
    func apply(_ rule: SSHForwardingRule, start: Bool) throws {
        guard rule.validationMessage == nil else { throw TunnelEditError.invalid }
        guard !pendingRemovals.contains(rule.id) else { throw TunnelEditError.unavailable }
        let exists = rules.contains { $0.id == rule.id }
        guard exists || rules.count < 16 else { throw TunnelEditError.limit }
        guard let client, client.updateForwarding(rule.nativeConfiguration, start: start) else {
            throw TunnelEditError.unavailable
        }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        statuses[rule.id] = SSHForwardingStatus(state: start ? "starting" : "stopping")
    }
    func remove(_ rule: SSHForwardingRule) throws {
        guard let client, client.removeForwarding(rule.id.uuidString) else { throw TunnelEditError.unavailable }
        pendingRemovals.insert(rule.id)
        statuses[rule.id]?.state = "stopping"
    }
    func disconnected() {
        client = nil
        rules.removeAll { pendingRemovals.contains($0.id) }
        pendingRemovals.removeAll()
        statuses = Dictionary(rules.map { ($0.id, SSHForwardingStatus()) }, uniquingKeysWith: { _, new in new })
    }
}

enum TunnelEditError: LocalizedError {
    case invalid, limit, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "Check the tunnel’s address and ports."
        case .limit: return "Keep at most 16 tunnels in a session."
        case .unavailable: return "The session is unavailable or busy. Wait, then try again."
        }
    }
}
