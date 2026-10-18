import Darwin
import Foundation

struct WireGuardConfiguration: Codable, Equatable {
    // Legacy type name retained for existing saved profile compatibility.
    var openVPN: Bool?
    var isOpenVPN: Bool { openVPN == true }
    var protocolName: String { isOpenVPN ? "OpenVPN" : "WireGuard" }
    var addresses = ""
    var dns = ""
    var publicKey = ""
    var endpoint = ""
    var allowedIPs = ""
    var keepalive = 25
    var mtu = 1420

    static func validKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }
    private static func validIP(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    private static func validList(_ value: String, prefix: Bool, optional: Bool = false) -> Bool {
        if optional && value.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return value.split(separator: ",", omittingEmptySubsequences: false).allSatisfy { part in
            let parts = part.trimmingCharacters(in: .whitespaces).split(
                separator: "/", omittingEmptySubsequences: false)
            guard let first = parts.first, validIP(String(first)) else { return false }
            if !prefix { return parts.count == 1 }
            guard parts.count == 2, let bits = Int(parts[1]) else { return false }
            return (0...(first.contains(":") ? 128 : 32)).contains(bits)
        }
    }
    var validationMessage: String? {
        if isOpenVPN { return nil }
        if !Self.validList(addresses, prefix: true) {
            return "Enter tunnel addresses with CIDR prefixes, separated by commas."
        }
        if !Self.validList(dns, prefix: false, optional: true) { return "Enter DNS IP addresses separated by commas." }
        if !Self.validKey(publicKey) { return "Enter the peer’s 32-byte base64 public key." }
        let url = URLComponents(string: "udp://" + endpoint)
        if endpoint.contains(where: { $0.isWhitespace }) || url?.host?.isEmpty != false || url?.user != nil
            || url?.password != nil || !(url?.path.isEmpty ?? false) || url?.query != nil || url?.fragment != nil
            || !(1...65535).contains(url?.port ?? 0)
        {
            return "Enter the WireGuard endpoint as host:port (use [address]:port for IPv6)."
        }
        if !Self.validList(allowedIPs, prefix: true) { return "Enter the peer’s AllowedIPs as CIDR prefixes." }
        if !(0...65535).contains(keepalive) { return "Keepalive must be between 0 and 65535 seconds." }
        if !(1280...1500).contains(mtu) { return "MTU must be between 1280 and 1500." }
        return nil
    }
}

struct WireGuardImport {
    var configuration: WireGuardConfiguration
    var privateKey: String
    var presharedKey: String

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw WireGuardError.invalidImport
        }
        var section = ""
        var sections = Set<String>()
        var fields: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[Interface]" || line == "[Peer]" {
                section = line
                guard sections.insert(section).inserted else { throw WireGuardError.invalidImport }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !section.isEmpty else { throw WireGuardError.invalidImport }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let allowed =
                section == "[Interface]"
                ? ["PrivateKey", "Address", "DNS", "MTU", "ListenPort"]
                : ["PublicKey", "PresharedKey", "Endpoint", "AllowedIPs", "PersistentKeepalive"]
            guard allowed.contains(name), fields[name] == nil else { throw WireGuardError.invalidImport }
            fields[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard sections.count == 2 else { throw WireGuardError.invalidImport }
        var configuration = WireGuardConfiguration()
        configuration.addresses = fields["Address"] ?? ""
        configuration.dns = fields["DNS"] ?? ""
        configuration.publicKey = fields["PublicKey"] ?? ""
        configuration.endpoint = fields["Endpoint"] ?? ""
        configuration.allowedIPs = fields["AllowedIPs"] ?? ""
        if let mtu = fields["MTU"] {
            guard let value = Int(mtu) else { throw WireGuardError.invalidImport }
            configuration.mtu = value
        }
        if let keepalive = fields["PersistentKeepalive"] {
            guard let value = Int(keepalive) else { throw WireGuardError.invalidImport }
            configuration.keepalive = value
        }
        let privateKey = fields["PrivateKey"] ?? ""
        let presharedKey = fields["PresharedKey"] ?? ""
        guard configuration.validationMessage == nil, WireGuardConfiguration.validKey(privateKey),
            presharedKey.isEmpty || WireGuardConfiguration.validKey(presharedKey)
        else { throw WireGuardError.invalidImport }
        return Self(configuration: configuration, privateKey: privateKey, presharedKey: presharedKey)
    }
}

enum WireGuardError: LocalizedError {
    case invalidImport, unavailable, missingKeys, transport, profileInUse
    case helperUnavailable, helperLaunch, initialization, endpointResolution, invalidConfiguration, startupTimeout,
        listener
    var errorDescription: String? {
        switch self {
        case .invalidImport:
            return
                "Use a WireGuard .conf with one Interface and one Peer, valid keys, addresses and endpoint. Scripts and extra settings are unsupported."
        case .unavailable:
            return "The selected VPN connection is unavailable. Choose an existing profile before connecting."
        case .missingKeys: return "VPN credentials are missing. Edit the VPN profile and save its credentials again."
        case .profileInUse:
            return "Disconnect sessions using this VPN profile before applying changed tunnel settings or keys."
        case .helperUnavailable:
            return "The embedded VPN helper is missing. Open the updated Farcast app or rebuild it."
        case .helperLaunch:
            return "macOS could not launch the embedded VPN helper. Rebuild or reinstall the complete app."
        case .initialization:
            return
                "The VPN stopped before the session could connect. For OpenVPN, check certificates, authentication and server settings."
        case .endpointResolution:
            return
                "The VPN endpoint hostname could not be resolved. Check the endpoint and this Mac’s network connection."
        case .invalidConfiguration:
            return
                "The VPN could not initialize this configuration. Check the imported VPN configuration and credentials. No server connection was attempted."
        case .startupTimeout:
            return
                "VPN initialization timed out. Check this Mac’s network connection and the endpoint."
        case .listener:
            return "The VPN could not create its private local listener. No server connection was attempted."
        case .transport:
            return
                "The VPN could not reach the private server. Check the VPN configuration, credentials, routes, DNS and server firewall. No direct connection was attempted."
        }
    }
}

struct WireGuardStartupResponse: Decodable {
    var port: Int?
    var error: String?
    func listenerPort() throws -> Int {
        if let port, (1...65535).contains(port), error == nil { return port }
        switch error {
        case "configuration": throw WireGuardError.invalidConfiguration
        case "endpoint_resolution": throw WireGuardError.endpointResolution
        case "listener": throw WireGuardError.listener
        default: throw WireGuardError.initialization
        }
    }
}
