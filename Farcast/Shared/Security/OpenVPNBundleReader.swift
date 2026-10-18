import Darwin
import Foundation

struct OpenVPNBundleReader {
    static func read(_ url: URL) throws -> OpenVPNImportDocument {
        guard url.isFileURL else { throw OpenVPNError.invalidImport }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw OpenVPNError.invalidArchive }
        let resources: [String: Data]
        if values.isDirectory == true {
            resources = try folder(url)
        } else if url.pathExtension.lowercased() == "zip" {
            resources = try BoundedZIP.read(readFile(url, maximum: 4 * 1024 * 1024))
        } else {
            guard ["ovpn", "conf"].contains(url.pathExtension.lowercased()) else { throw OpenVPNError.invalidImport }
            // A file picker grants access to this file only. Request companions explicitly.
            return try OpenVPNImportDocument(data: readFile(url))
        }
        let configs = resources.keys.filter { ["ovpn", "conf"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard configs.count == 1, let config = configs.first, let data = resources[config] else {
            throw configs.count > 1 ? OpenVPNError.ambiguousBundle : OpenVPNError.invalidArchive
        }
        let parent = (config as NSString).deletingLastPathComponent
        return try OpenVPNImportDocument(
            data: data, resources: resources, directory: parent.isEmpty ? "" : parent + "/")
    }

    static func readFile(_ url: URL, maximum: Int = 262_144) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw OpenVPNError.invalidCompanion }
        defer { close(fd) }
        return try readDescriptor(fd, maximum: maximum)
    }

    private static func readDescriptor(_ fd: Int32, maximum: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= maximum else {
            throw OpenVPNError.invalidCompanion
        }
        var buffer = [UInt8](repeating: 0, count: maximum + 1)
        var count = 0
        while count < buffer.count {
            let size = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if size == 0 { break }
            if size < 0 {
                if errno == EINTR { continue }
                throw OpenVPNError.invalidCompanion
            }
            count += size
        }
        guard count <= maximum else { throw OpenVPNError.invalidCompanion }
        return Data(buffer.prefix(count))
    }

    private static func folder(_ selected: URL) throws -> [String: Data] {
        let root = selected.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OpenVPNError.invalidArchive }
        defer { close(fd) }
        var failed = false
        guard
            let entries = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
                errorHandler: { _, _ in
                    failed = true
                    return false
                })
        else { throw OpenVPNError.invalidArchive }
        var result: [String: Data] = [:]
        var count = 0
        var total = 0
        var names = Set<String>()
        for case let file as URL in entries {
            count += 1
            guard count <= 64 else { throw OpenVPNError.invalidArchive }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw OpenVPNError.invalidArchive }
            if values.isDirectory == true { continue }
            let rootComponents = root.pathComponents
            let fileComponents = file.standardizedFileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else { throw OpenVPNError.invalidArchive }
            let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
            guard BoundedZIP.safePath(relative), names.insert(relative.lowercased()).inserted else {
                throw OpenVPNError.invalidArchive
            }
            // Resolve each component relative to a pinned directory, never follow symlinks.
            var parent = dup(fd)
            guard parent >= 0 else { throw OpenVPNError.invalidArchive }
            defer { close(parent) }
            let parts = relative.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw OpenVPNError.invalidArchive }
                close(parent)
                parent = next
            }
            let child = openat(parent, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard child >= 0 else { throw OpenVPNError.invalidArchive }
            defer { close(child) }
            let data = try readDescriptor(child, maximum: 1_048_576)
            total += data.count
            guard total <= 4 * 1024 * 1024 else { throw OpenVPNError.invalidArchive }
            result[relative] = data
        }
        guard !failed else { throw OpenVPNError.invalidArchive }
        return result
    }
}
