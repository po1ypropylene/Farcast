import Foundation

/// The entire imported profile is secret-bearing and belongs in CredentialStore.
/// Never persist it in SwiftData or include parser input in error messages.
struct OpenVPNImport {
    let profile: String
    let requiresPassword: Bool

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8),
            !text.contains("\0")
        else { throw OpenVPNError.invalidImport }
        let blocks: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs"]
        let options: Set<String> = [
            "client", "tls-client", "dev", "dev-type", "proto", "remote", "remote-random", "resolv-retry",
            "nobind", "persist-key", "persist-tun", "auth-user-pass", "auth-nocache", "remote-cert-tls",
            "verify-x509-name", "tls-version-min", "tls-version-max", "tls-cipher", "tls-ciphersuites",
            "cipher", "data-ciphers", "auth", "key-direction", "reneg-sec", "verb", "mute", "pull",
            "route", "route-ipv6", "route-metric", "redirect-gateway", "dhcp-option", "topology",
            "ifconfig", "ifconfig-ipv6", "tun-mtu", "mssfix", "explicit-exit-notify", "connect-timeout",
            "connect-retry", "connect-retry-max", "ping", "ping-restart", "keepalive", "float",
        ]
        var block: String?
        var seenBlocks = Set<String>()
        var hasRemote = false
        var hasClient = false
        var hasTUN = false
        var requiresPassword = false
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let active = block {
                if line == "</\(active)>" {
                    block = nil
                } else if line.hasPrefix("<") {
                    throw OpenVPNError.invalidImport
                }
                lines.append(line)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("<") {
                guard line.hasSuffix(">") else { throw OpenVPNError.invalidImport }
                let name = String(line.dropFirst().dropLast())
                guard blocks.contains(name), seenBlocks.insert(name).inserted else { throw OpenVPNError.invalidImport }
                block = name
                lines.append(line)
                continue
            }
            let words = try tokens(line)
            guard let option = words.first, options.contains(option) else { throw OpenVPNError.invalidImport }
            switch option {
            case "client", "tls-client": hasClient = true
            case "remote":
                guard (2...4).contains(words.count) else { throw OpenVPNError.invalidImport }
                hasRemote = true
            case "dev", "dev-type":
                guard words == [option, "tun"] else { throw OpenVPNError.invalidImport }
                hasTUN = true
            case "auth-user-pass":
                guard words.count == 1 else { throw OpenVPNError.invalidImport }
                requiresPassword = true
            case "remote-cert-tls":
                guard words == [option, "server"] else { throw OpenVPNError.invalidImport }
            case "tls-version-min":
                guard words.count == 2, ["1.2", "1.3"].contains(words[1]) else { throw OpenVPNError.invalidImport }
            case "proto":
                guard words.count == 2,
                    ["udp", "udp4", "udp6", "tcp-client", "tcp4-client", "tcp6-client"].contains(words[1])
                else { throw OpenVPNError.invalidImport }
            default: break
            }
            lines.append(line)
        }
        guard block == nil, hasClient, hasRemote, hasTUN, seenBlocks.contains("ca"),
            seenBlocks.contains("cert") == seenBlocks.contains("key"),
            requiresPassword || seenBlocks.contains("cert")
        else { throw OpenVPNError.invalidImport }
        // Always enforce the server certificate purpose; this is not an accept-all trust mode.
        if !lines.contains("remote-cert-tls server") { lines.append("remote-cert-tls server") }
        let profile = lines.joined(separator: "\n") + "\n"
        guard profile.utf8.count <= 262_144 else { throw OpenVPNError.invalidImport }
        return Self(profile: profile, requiresPassword: requiresPassword)
    }

    private static func tokens(_ line: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let active = quote {
                if character == active { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" || character == ";" {
                break
            } else if character.isWhitespace {
                if !token.isEmpty {
                    result.append(token)
                    token = ""
                }
            } else {
                token.append(character)
            }
        }
        guard quote == nil, !escaped else { throw OpenVPNError.invalidImport }
        if !token.isEmpty { result.append(token) }
        return result
    }
}

enum OpenVPNError: LocalizedError {
    case invalidImport, missingCredentials
    var errorDescription: String? {
        switch self {
        case .invalidImport:
            return
                "Import a self-contained OpenVPN client .ovpn file with a TUN device, inline CA and certificate/key or username/password authentication. External files, scripts, plugins, proxies, TAP, compression and interactive MFA are unsupported."
        case .missingCredentials:
            return "Import an OpenVPN profile and enter its required credentials in VPN Connections."
        }
    }
}
