import Foundation

/// Owner-only credential records; app records use the library’s selected protection.
struct LocalCredentialStore {
    let root: URL
    let storage: ConnectionStorage?

    init(root: URL, storage: ConnectionStorage? = nil) {
        self.root = root
        self.storage = storage
    }

    private func file(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }

    private func prepare() throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    func load(_ id: UUID) throws -> ConnectionCredential? {
        guard FileManager.default.fileExists(atPath: file(id).path) else { return nil }
        try prepare()
        let values = try file(id).resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw CocoaError(.fileReadNoPermission)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
        return try JSONDecoder().decode(ConnectionCredential.self, from: decoded(id))
    }

    private func decoded(_ id: UUID) throws -> Data {
        let data = try StorageFile.read(file(id))
        return try storage?.decode(data, context: id.uuidString) ?? data
    }

    func save(_ credential: ConnectionCredential, for id: UUID) throws {
        try prepare()
        let data = try JSONEncoder().encode(credential)
        let encoded = try storage?.encode(data, context: id.uuidString) ?? data
        try StorageFile.write(encoded, to: file(id))
    }

    func delete(_ id: UUID) throws {
        if FileManager.default.fileExists(atPath: file(id).path) {
            try prepare()
            try FileManager.default.removeItem(at: file(id))
        }
    }
}
