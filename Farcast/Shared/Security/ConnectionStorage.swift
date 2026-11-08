import CommonCrypto
import CryptoKit
import Darwin
import Foundation

enum CredentialProtection: String, Codable, CaseIterable, Identifiable {
    case keyFile, password, unencrypted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyFile: return "Key file (AES-128)"
        case .password: return "Password (AES-128)"
        case .unencrypted: return "Unencrypted"
        }
    }
}

enum ConnectionStorageError: LocalizedError {
    case locked, invalid, exists
    var errorDescription: String? {
        switch self {
        case .locked: return "Unlock the connection library before using saved credentials."
        case .invalid: return "The library, password or key file is invalid or inaccessible. No data was replaced."
        case .exists: return "The destination already contains data. Choose an empty folder."
        }
    }
}

/// Shared on-disk format for the app and the explicitly invoked migration tool.
struct ConnectionStorageManifest: Codable {
    var version = 1
    var protection: CredentialProtection
    var credentialsDirectory = "Credentials"
    var keyFile: String?
    var salt: Data?
    var verification: Data?
}

enum StorageFile {
    static func directory(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw ConnectionStorageError.invalid }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func read(_ url: URL, limit: Int = 16 * 1_024 * 1_024) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ConnectionStorageError.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size >= 0, info.st_size <= limit
        else { throw ConnectionStorageError.invalid }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count == info.st_size else { throw ConnectionStorageError.invalid }
        return data
    }

    static func write(_ data: Data, to url: URL, replace: Bool = true) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConnectionStorageError.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        if replace {
            guard rename(temporary.path, url.path) == 0 else { throw ConnectionStorageError.invalid }
        } else {
            guard link(temporary.path, url.path) == 0 else { throw ConnectionStorageError.exists }
        }
    }
}

final class ConnectionStorage {
    let root: URL
    let manifest: ConnectionStorageManifest
    private let key: SymmetricKey?
    private(set) var supersededFilesRemain = false
    static var realHome: URL {
        URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir), isDirectory: true)
    }
    static var defaultRoot: URL { realHome.appendingPathComponent(".farcast-connections", isDirectory: true) }
    static var defaultKey: URL { realHome.appendingPathComponent(".farcast-key") }
    var credentials: LocalCredentialStore {
        LocalCredentialStore(root: root.appendingPathComponent(manifest.credentialsDirectory), storage: self)
    }
    static func manifest(at root: URL) throws -> ConnectionStorageManifest {
        let manifest = try JSONDecoder().decode(
            ConnectionStorageManifest.self, from: StorageFile.read(root.appendingPathComponent("storage.json")))
        let directory = manifest.credentialsDirectory
        guard manifest.version == 1,
            directory == "Credentials"
                || (directory.hasPrefix("Credentials-") && UUID(uuidString: String(directory.dropFirst(12))) != nil)
        else { throw ConnectionStorageError.invalid }
        return manifest
    }

    static func open(_ root: URL, password: String = "") throws -> ConnectionStorage {
        try StorageFile.directory(root)
        let manifest = try manifest(at: root)
        let key = try encryptionKey(manifest, password: password)
        let storage = ConnectionStorage(root: root, manifest: manifest, key: key)
        if manifest.protection != .unencrypted {
            guard let verification = manifest.verification,
                try storage.decode(verification, context: "library") == Data("Farcast storage v1".utf8)
            else { throw ConnectionStorageError.invalid }
        }
        return storage
    }

    static func create(
        _ root: URL, protection: CredentialProtection = .keyFile, keyFile: URL = defaultKey,
        password: String = "", credentialsDirectory: String = "Credentials"
    ) throws -> ConnectionStorage {
        try StorageFile.directory(root)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("storage.json").path) else {
            throw ConnectionStorageError.exists
        }
        var manifest = ConnectionStorageManifest(protection: protection, credentialsDirectory: credentialsDirectory)
        if protection == .keyFile {
            manifest.keyFile = keyFile.path
            if !FileManager.default.fileExists(atPath: keyFile.path) {
                let bytes = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
                try StorageFile.write(bytes, to: keyFile, replace: false)
            }
        } else if protection == .password {
            guard !password.isEmpty else { throw ConnectionStorageError.invalid }
            manifest.salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        }
        let key = try encryptionKey(manifest, password: password)
        var storage = ConnectionStorage(root: root, manifest: manifest, key: key)
        if protection != .unencrypted {
            manifest.verification = try storage.encode(Data("Farcast storage v1".utf8), context: "library")
            storage = ConnectionStorage(root: root, manifest: manifest, key: key)
        }
        try StorageFile.directory(storage.credentials.root)
        try StorageFile.write(
            try JSONEncoder().encode(manifest), to: root.appendingPathComponent("storage.json"), replace: false)
        return storage
    }

    private init(root: URL, manifest: ConnectionStorageManifest, key: SymmetricKey?) {
        self.root = root
        self.manifest = manifest
        self.key = key
    }

    private static func encryptionKey(_ manifest: ConnectionStorageManifest, password: String) throws -> SymmetricKey? {
        switch manifest.protection {
        case .unencrypted: return nil
        case .keyFile:
            guard let path = manifest.keyFile else { throw ConnectionStorageError.invalid }
            let data = try StorageFile.read(URL(fileURLWithPath: path), limit: 16)
            guard data.count == 16 else { throw ConnectionStorageError.invalid }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return SymmetricKey(data: data)
        case .password:
            guard let salt = manifest.salt, salt.count == 16, !password.isEmpty else {
                throw ConnectionStorageError.invalid
            }
            var output = Data(count: 16)
            let bytes = Array(password.utf8)
            let status = output.withUnsafeMutableBytes { out in
                salt.withUnsafeBytes { saltBytes in
                    bytes.withUnsafeBytes { passwordBytes in
                        CCKeyDerivationPBKDF(
                            CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                            bytes.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                            out.baseAddress!.assumingMemoryBound(to: UInt8.self), 16)
                    }
                }
            }
            guard status == kCCSuccess else { throw ConnectionStorageError.invalid }
            return SymmetricKey(data: output)
        }
    }

    func encode(_ data: Data, context: String) throws -> Data {
        guard let key else { return data }
        return try AES.GCM.seal(data, using: key, authenticating: Data("farcast.v1.\(context)".utf8)).combined!
    }
    func decode(_ data: Data, context: String) throws -> Data {
        guard let key else { return data }
        return try AES.GCM.open(
            AES.GCM.SealedBox(combined: data), using: key, authenticating: Data("farcast.v1.\(context)".utf8))
    }

    /// Stage all records before atomically changing the manifest. Failed changes leave the old store usable.
    func changingProtection(_ protection: CredentialProtection, keyFile: URL, password: String) throws
        -> ConnectionStorage
    {
        let stage = root.appendingPathComponent(".storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        let name = "Credentials-\(UUID())"
        let next = try Self.create(
            stage, protection: protection, keyFile: keyFile, password: password, credentialsDirectory: name)
        for id in try credentialIDs() {
            guard let credential = try credentials.load(id) else { throw ConnectionStorageError.invalid }
            try next.credentials.save(credential, for: id)
        }
        let destination = root.appendingPathComponent(name)
        try FileManager.default.moveItem(at: next.credentials.root, to: destination)
        do {
            try StorageFile.write(
                try JSONEncoder().encode(next.manifest), to: root.appendingPathComponent("storage.json"))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let result = ConnectionStorage(root: root, manifest: next.manifest, key: next.key)
        // Remove superseded plaintext as well as encrypted records after the manifest commit.
        do { try FileManager.default.removeItem(at: credentials.root) } catch { result.supersededFilesRemain = true }
        return result
    }

    func credentialIDs() throws -> [UUID] {
        try StorageFile.directory(credentials.root)
        return try FileManager.default.contentsOfDirectory(atPath: credentials.root.path).map {
            guard $0.hasSuffix(".json"), let id = UUID(uuidString: String($0.dropLast(5))),
                $0 == id.uuidString + ".json"
            else {
                throw ConnectionStorageError.invalid
            }
            return id
        }
    }
}

/// Serializes credential access and library/protection switches. A nil store selects the original mode.
enum ConnectionStorageSession {
    private static let lock = NSRecursiveLock()
    private static var active: ConnectionStorage?
    static func use(_ storage: ConnectionStorage?) {
        lock.lock()
        defer { lock.unlock() }
        active = storage
    }
    static func withOptionalStorage<T>(_ action: (ConnectionStorage?) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action(active)
    }
    static func withStorage<T>(_ action: (ConnectionStorage) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { throw ConnectionStorageError.locked }
        return try action(active)
    }
    static func changeProtection(_ protection: CredentialProtection, keyFile: URL, password: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let active else { throw ConnectionStorageError.locked }
        self.active = try active.changingProtection(protection, keyFile: keyFile, password: password)
    }
}
