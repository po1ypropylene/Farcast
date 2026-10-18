import Foundation

enum OpenVPNFileRole: String, CaseIterable, Identifiable {
    case ca, cert, key
    case tlsAuth = "tls-auth"
    case tlsCrypt = "tls-crypt"
    case tlsCryptV2 = "tls-crypt-v2"
    case extraCerts = "extra-certs"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ca: return "CA certificate"
        case .cert: return "Client certificate"
        case .key: return "Private key"
        case .tlsAuth: return "TLS authentication key"
        case .tlsCrypt: return "TLS encryption key"
        case .tlsCryptV2: return "TLS encryption v2 key"
        case .extraCerts: return "Additional certificates"
        }
    }
}

/// Uncommitted import review. Original input never becomes a library record.
struct OpenVPNImportDocument {
    var source: String
    var references: [OpenVPNFileRole: String] = [:]
    var files: [OpenVPNFileRole: Data] = [:]
    var needsLegacyCompression = false
    var allowLegacyCompression = false
    var isTAP = false

    init(data: Data, resources: [String: Data] = [:], directory: String = "") throws {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw OpenVPNError.invalidImport
        }
        var lines: [String] = []
        var block: String?
        var roles = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let active = block {
                lines.append(line)
                if line == "</\(active)>" { block = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">") {
                let tag = String(line.dropFirst().dropLast())
                guard roles.insert(tag).inserted else { throw OpenVPNError.invalidImport }
                block = tag
                lines.append(line)
                continue
            }
            let words = try OpenVPNImport.tokens(line)
            guard let option = words.first else { continue }
            // Consent belongs to this review, not to an untrusted imported marker.
            if words == ["setenv", "FARCAST_LEGACY_COMPRESSION", "1"] { continue }
            if ["dev", "dev-type"].contains(option), words.dropFirst().contains(where: { $0.hasPrefix("tap") }) {
                isTAP = true
            }
            if option == "comp-lzo", words.count == 1 || words.dropFirst().contains(where: { $0 != "no" }) {
                needsLegacyCompression = true
            }
            if let role = OpenVPNFileRole(rawValue: option) {
                guard (2...3).contains(words.count), roles.insert(option).inserted,
                    words.count == 2 || (role == .tlsAuth && ["0", "1"].contains(words[2]))
                else {
                    throw OpenVPNError.invalidImport
                }
                references[role] = words[1]
                if BoundedZIP.safePath(words[1]), !words[1].hasSuffix("/") {
                    files[role] = resources[directory + words[1]]
                }
                if words.count == 3 { lines.append("key-direction \(words[2])") }
                continue
            }
            lines.append(line)
        }
        guard block == nil else { throw OpenVPNError.invalidImport }
        source = lines.joined(separator: "\n") + "\n"
    }

    var requiredFiles: [OpenVPNFileRole] { OpenVPNFileRole.allCases.filter { references[$0] != nil } }
    var missingFiles: [OpenVPNFileRole] { requiredFiles.filter { files[$0] == nil } }
    func assemble() throws -> OpenVPNImport {
        if isTAP { throw OpenVPNError.tapUnsupported }
        guard missingFiles.isEmpty else { throw OpenVPNError.missingFiles }
        var content = source
        if needsLegacyCompression && allowLegacyCompression { content += "setenv FARCAST_LEGACY_COMPRESSION 1\n" }
        for role in requiredFiles {
            guard let data = files[role], data.count <= 262_144,
                let text = String(data: data, encoding: .utf8), !text.contains("\0"),
                !text.contains("<"), !text.contains(">"), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw OpenVPNError.invalidCompanion }
            content += "<\(role.rawValue)>\n\(text)\n</\(role.rawValue)>\n"
        }
        return try OpenVPNImport.parse(Data(content.utf8))
    }
}
