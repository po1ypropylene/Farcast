import Foundation

/// Editing snapshot only. Secret fields must never be encoded into the metadata library.
struct VPNProfileDraft: Equatable {
    var name = "Untitled VPN"
    var configuration = WireGuardConfiguration()
    var privateKey = ""
    var presharedKey = ""
    var mtu = "1420"
    var keepalive = "25"
    var openVPNProfile = ""
    var username = ""
    var password = ""
    var passphrase = ""
    // The selected filename is transient; existing profiles still show their parsed summary.
    var importedFilename: String?

    var fieldOrder: [String] {
        configuration.isOpenVPN
            ? ["name", "import", "username", "password", "passphrase"]
            : [
                "name", "address", "privateKey", "publicKey", "endpoint", "allowedIPs", "dns", "mtu", "presharedKey",
                "keepalive",
            ]
    }

    func issues(existingNames: [String]) -> [String: String] {
        var result: [String: String] = [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            result["name"] = "Enter a profile name."
        } else if existingNames.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            result["name"] = "A profile with this name already exists."
        }
        if configuration.isOpenVPN {
            guard let imported = try? OpenVPNImport.parse(Data(openVPNProfile.utf8)) else {
                result["import"] = "Import a supported OpenVPN .ovpn file."
                return result
            }
            if imported.requiresPassword {
                if username.isEmpty { result["username"] = "Enter the OpenVPN username." }
                if password.isEmpty { result["password"] = "Enter the OpenVPN password." }
            }
            return result
        }
        if !WireGuardConfiguration.validList(configuration.addresses, prefix: true) {
            result["address"] = "Use CIDR notation, e.g. 10.0.0.2/32."
        }
        for (field, value) in [("privateKey", privateKey), ("publicKey", configuration.publicKey)] {
            if value.count != 44 || !WireGuardConfiguration.validKey(value) {
                result[field] = "Enter a valid 44-character key."
            }
        }
        if !presharedKey.isEmpty && (presharedKey.count != 44 || !WireGuardConfiguration.validKey(presharedKey)) {
            result["presharedKey"] = "Enter a valid 44-character key."
        }
        if !WireGuardConfiguration.validEndpoint(configuration.endpoint) {
            result["endpoint"] = "Use host:port, with a port from 1 to 65535."
        }
        if !WireGuardConfiguration.validList(configuration.allowedIPs, prefix: true) {
            result["allowedIPs"] = "Enter IP ranges in CIDR notation, separated by commas."
        }
        if !WireGuardConfiguration.validList(configuration.dns, prefix: false, optional: true) {
            result["dns"] = "Enter IP addresses separated by commas."
        }
        if !(1280...1500).contains(Int(mtu) ?? 0) { result["mtu"] = "Enter an MTU from 1280 to 1500." }
        if !(0...65535).contains(Int(keepalive) ?? -1) { result["keepalive"] = "Enter seconds from 0 to 65535." }
        return result
    }
}
