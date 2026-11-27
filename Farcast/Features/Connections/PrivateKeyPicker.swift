import AppKit
import CryptoKit

struct ImportedKey {
    let data: Data
    let name: String
}
struct PrivateKeyPicker {
    static func pick() throws -> ImportedKey? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your SSH private key. Farcast imports it securely; your file is not modified."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8), text.contains("PRIVATE KEY")
        else { throw CocoaError(.fileReadCorruptFile) }
        return ImportedKey(data: data, name: url.lastPathComponent)
    }
}

struct PrivateKeyDetails {
    var encrypted = true
    var description: String?
    init(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else {
            encrypted = text.contains("ENCRYPTED")
            description = text.components(separatedBy: .newlines).first?.replacingOccurrences(of: "-----", with: "")
                .replacingOccurrences(of: "BEGIN ", with: "")
            return
        }
        let encoded = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        let magic = Data("openssh-key-v1\0".utf8)
        guard let raw = Data(base64Encoded: encoded), raw.starts(with: magic) else { return }
        var offset = magic.count
        func integer(_ bytes: Data, _ index: inout Int) -> Int? {
            guard bytes.count - index >= 4 else { return nil }
            defer { index += 4 }
            return bytes[index..<index + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        func field(_ bytes: Data, _ index: inout Int) -> Data? {
            guard let count = integer(bytes, &index), count <= bytes.count - index else { return nil }
            defer { index += count }
            return bytes.subdata(in: index..<index + count)
        }
        guard let cipher = field(raw, &offset), field(raw, &offset) != nil, field(raw, &offset) != nil,
            integer(raw, &offset) == 1, let blob = field(raw, &offset)
        else { return }
        encrypted = cipher != Data("none".utf8)
        var start = 0
        guard let algorithm = field(blob, &start), let name = String(data: algorithm, encoding: .utf8) else { return }
        let fingerprint = Data(SHA256.hash(data: blob)).base64EncodedString()
        description = "\(name) · SHA256:\(fingerprint.prefix(14))…"
    }
}
