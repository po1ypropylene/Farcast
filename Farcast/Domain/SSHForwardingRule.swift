import Darwin
import Foundation

enum SSHForwardingKind: String, Codable, CaseIterable, Identifiable {
    case local, socks, remote
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "Local forward"
        case .socks: return "SOCKS5 proxy"
        case .remote: return "Remote forward"
        }
    }
    var explanation: String {
        switch self {
        case .local: return "Open a port on this Mac that reaches a host the server can reach."
        case .socks: return "Route apps on this Mac through the SSH server."
        case .remote: return "Open a port on the server that reaches a host on this Mac’s side."
        }
    }
}

enum SSHForwardingField: String, CaseIterable, Hashable {
    case listenAddress, listenPort, destinationHost, destinationPort
}

struct SSHForwardingRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind = SSHForwardingKind.local
    var bindAddress = "127.0.0.1"
    var bindPort = 0
    var destinationHost = "127.0.0.1"
    var destinationPort = 0
    var enabled = true
    var validationMessage: String? {
        SSHForwardingField.allCases.compactMap { validationMessage(for: $0) }.first
    }
    func validationMessage(for field: SSHForwardingField) -> String? {
        switch field {
        case .listenPort:
            return (0...65535).contains(bindPort) ? nil : "Use Auto or a listen port between 1 and 65535."
        case .listenAddress:
            if kind != .remote && !["127.0.0.1", "::1"].contains(bindAddress) {
                return "Local tunnels and proxies must listen on 127.0.0.1 or ::1."
            }
            if kind == .remote && !Self.isNumericAddress(bindAddress) {
                return "Remote tunnel listen address must be an IPv4 or IPv6 address."
            }
        case .destinationPort:
            if kind != .socks && !(1...65535).contains(destinationPort) {
                return "Enter a destination port between 1 and 65535."
            }
        case .destinationHost:
            if kind != .socks {
                let host = destinationHost
                if host.isEmpty || host.utf8.count > 255
                    || host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    || host.contains(where: { $0.isWhitespace || ($0.isASCII && $0.asciiValue! < 32) })
                    || host.contains("/") || host.contains("\0") || (host.contains(":") && !Self.isNumericAddress(host))
                {
                    return "Enter a tunnel destination host or IP address without a URL or port."
                }
            }
        }
        return nil
    }
    static func newRule() -> SSHForwardingRule { SSHForwardingRule(destinationHost: "") }
    var exposesListener: Bool { kind == .remote && !["127.0.0.1", "::1"].contains(bindAddress) }
    var displayListener: String { endpoint(bindAddress, port: bindPort) }
    func pathSummary(server: String) -> String {
        let server = server.isEmpty ? "SSH server" : server
        switch kind {
        case .local:
            return
                "Mac \(displayListener) → \(server) → \(endpoint(destinationHost, port: destinationPort, automatic: false))"
        case .socks: return "Mac \(displayListener) → \(server) → app destinations"
        case .remote:
            return
                "\(server) \(displayListener) → Mac → \(endpoint(destinationHost, port: destinationPort, automatic: false))"
        }
    }
    func endpoint(_ host: String, port: Int, automatic: Bool = true) -> String {
        let host = host.isEmpty ? "host" : host.contains(":") ? "[\(host)]" : host
        return "\(host):\(port == 0 ? (automatic ? "Auto" : "Port") : String(port))"
    }
    var listenerLabel: String { "\(bindAddress.contains(":") ? "[\(bindAddress)]" : bindAddress):\(bindPort)" }
    var destinationLabel: String {
        kind == .socks
            ? "Destinations requested by local applications"
            : "\(destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost):\(destinationPort)"
    }
    var nativeConfiguration: [String: Any] {
        [
            "id": id.uuidString, "kind": kind.rawValue, "bind": bindAddress, "port": bindPort,
            "host": destinationHost, "destinationPort": destinationPort, "enabled": enabled,
        ]
    }
    private static func isNumericAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
