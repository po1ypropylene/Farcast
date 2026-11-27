import Foundation

struct FileTransferSettings: Codable, Equatable {
    enum Method: String, Codable, CaseIterable {
        case automatic, rsyncOnly, sftpOnly
        var title: String {
            switch self {
            case .automatic: return "Automatic (rsync when available)"
            case .rsyncOnly: return "rsync only"
            case .sftpOnly: return "SFTP only"
            }
        }
    }
    var method = Method.automatic
    var compress = false
    var remoteRsyncPath: String?
    var extraRsyncArgs: [String] = []

    var validationMessage: String? {
        if let path = remoteRsyncPath,
            !path.hasPrefix("/") || path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        {
            return "Enter an absolute remote rsync path."
        }
        // Transport, deletion, source selection, shell and output options belong to Farcast.
        for option in extraRsyncArgs {
            if ["--checksum", "--whole-file", "--sparse"].contains(option) { continue }
            if option.range(of: #"^--bwlimit=[0-9]{1,9}$"#, options: .regularExpression) != nil { continue }
            return "Supported options are --checksum, --whole-file, --sparse and --bwlimit=NUMBER."
        }
        return nil
    }
}

struct RsyncInstall: Equatable {
    let path: String
    let version: String
    let openRsync: Bool
    private let numbers: [Int]
    private let suffix: String

    init?(path: String, output: String) {
        let lines = output.components(separatedBy: .newlines)
        let open = lines.first?.hasPrefix("openrsync:") == true
        let line = open ? lines.dropFirst().first ?? "" : lines.first ?? ""
        let pattern = #"^rsync\s+version\s+([0-9]+(?:\.[0-9]+)+)([A-Za-z][A-Za-z0-9.-]*)?(?:\s|$)"#
        guard path.hasPrefix("/"), let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let numeric = Range(match.range(at: 1), in: line)
        else { return nil }
        let components = line[numeric].split(separator: ".")
        let values = components.compactMap { Int($0) }
        guard values.count == components.count else { return nil }
        suffix = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
        version = String(line[numeric]) + suffix
        numbers = values
        self.path = path
        openRsync = open
    }

    static func ranked(_ installs: [Self], override: String?) -> [Self] {
        installs.enumerated().sorted { a, b in
            let x = a.element
            let y = b.element
            if (x.path == override) != (y.path == override) { return x.path == override }
            for i in 0..<max(x.numbers.count, y.numbers.count) {
                let l = i < x.numbers.count ? x.numbers[i] : 0
                let r = i < y.numbers.count ? y.numbers[i] : 0
                if l != r { return l > r }
            }
            if x.suffix.isEmpty != y.suffix.isEmpty { return x.suffix.isEmpty }
            if x.suffix != y.suffix { return x.suffix.compare(y.suffix, options: .numeric) == .orderedDescending }
            if x.openRsync != y.openRsync { return !x.openRsync }
            if (x.path == "/usr/bin/rsync") != (y.path == "/usr/bin/rsync") { return y.path == "/usr/bin/rsync" }
            return a.offset < b.offset
        }.map(\.element)
    }
}
