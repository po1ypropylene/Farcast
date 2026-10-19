import Foundation

/// Metadata-only import. Never follows Include, loads keys, or executes SSH directives.
struct SSHConfigImport {
    struct Entry: Identifiable {
        let id = UUID()
        let alias: String
        let host: String
        let username: String
        let port: Int
    }
    enum ImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "The selected SSH config is too large or contains invalid quoted values." }
    }
    let entries: [Entry]

    init(text: String) throws {
        guard text.utf8.count <= 1_048_576 else { throw ImportError.invalid }
        var blocks: [(hosts: [String], options: [String: String])] = []
        var hosts: [String] = []
        var options: [String: String] = [:]
        var inMatch = false
        for line in text.components(separatedBy: .newlines) {
            let words = try Self.words(line)
            guard let first = words.first else { continue }
            let key = first.lowercased()
            let values = Array(words.dropFirst())
            if key == "host" || key == "match" {
                blocks.append((hosts, options))
                options = [:]
                hosts = key == "host" ? values : []
                inMatch = key == "match"
            } else if !inMatch, let value = values.first, options[key] == nil {
                options[key] = value
            }
        }
        blocks.append((hosts, options))
        var result: [Entry] = []
        var seen = Set<String>()
        for block in blocks {
            for alias in block.hosts where !alias.contains(where: { "*?!%".contains($0) }) {
                guard seen.insert(alias.lowercased()).inserted else { continue }
                // Retain OpenSSH's first-value-wins defaults for matching Host blocks.
                var effective: [String: String] = [:]
                for candidate in blocks where candidate.hosts.isEmpty || Self.matches(alias, candidate.hosts) {
                    for (key, value) in candidate.options where effective[key] == nil { effective[key] = value }
                }
                guard effective["proxycommand"].map({ $0.lowercased() != "none" }) != true,
                    effective["proxyjump"].map({ $0.lowercased() != "none" }) != true
                else { continue }
                let host = (effective["hostname"] ?? alias).replacingOccurrences(of: "%h", with: alias)
                let user = effective["user"] ?? ""
                guard !host.isEmpty, !host.contains("%"), !user.contains("%"),
                    let port = Int(effective["port"] ?? "22"), (1...65535).contains(port)
                else { continue }
                result.append(Entry(alias: alias, host: host, username: user, port: port))
                guard result.count <= 2_000 else { throw ImportError.invalid }
            }
        }
        entries = result
    }

    private static func matches(_ alias: String, _ patterns: [String]) -> Bool {
        var positive = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let raw = negated ? String(pattern.dropFirst()) : pattern
            let regex =
                "^"
                + NSRegularExpression.escapedPattern(for: raw)
                .replacingOccurrences(of: "\\*", with: ".*").replacingOccurrences(of: "\\?", with: ".") + "$"
            if alias.range(of: regex, options: [.regularExpression, .caseInsensitive]) != nil {
                if negated { return false }
                positive = true
            }
        }
        return positive
    }

    private static func words(_ line: String) throws -> [String] {
        var result: [String] = []
        var value = ""
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping {
                value.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let current = quote {
                if character == current { quote = nil } else { value.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            } else if character.isWhitespace || (character == "=" && result.count <= 1) {
                if !value.isEmpty {
                    result.append(value)
                    value = ""
                }
            } else {
                value.append(character)
            }
        }
        guard quote == nil, !escaping else { throw ImportError.invalid }
        if !value.isEmpty { result.append(value) }
        return result
    }
}
