import Foundation
import zlib

/// Small, in-memory ZIP reader for user-selected VPN bundles. Never extracts paths.
struct BoundedZIP {
    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func readLittleEndian(_ offset: Int, _ byteCount: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - byteCount else { throw OpenVPNError.invalidArchive }
            return (0..<byteCount).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22, bytes.count <= 4 * 1024 * 1024 else { throw OpenVPNError.invalidArchive }
        var endOfCentralDirectoryOffset: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try readLittleEndian(offset, 4) == 0x0605_4b50,
                offset + 22 + (try readLittleEndian(offset + 20, 2)) == bytes.count
            {
                endOfCentralDirectoryOffset = offset
                break
            }
        }
        guard let endOfCentralDirectoryOffset, try readLittleEndian(endOfCentralDirectoryOffset + 4, 2) == 0,
            try readLittleEndian(endOfCentralDirectoryOffset + 6, 2) == 0
        else {
            throw OpenVPNError.invalidArchive
        }
        let entryCount = try readLittleEndian(endOfCentralDirectoryOffset + 10, 2)
        let directorySize = try readLittleEndian(endOfCentralDirectoryOffset + 12, 4)
        var directoryEntryOffset = try readLittleEndian(endOfCentralDirectoryOffset + 16, 4)
        guard (1...64).contains(entryCount), try readLittleEndian(endOfCentralDirectoryOffset + 8, 2) == entryCount,
            directoryEntryOffset + directorySize == endOfCentralDirectoryOffset
        else {
            throw OpenVPNError.invalidArchive
        }
        var result: [String: Data] = [:]
        var names = Set<String>()
        var totalExpandedSize = 0
        for _ in 0..<entryCount {
            guard try readLittleEndian(directoryEntryOffset, 4) == 0x0201_4b50 else {
                throw OpenVPNError.invalidArchive
            }
            let flags = try readLittleEndian(directoryEntryOffset + 8, 2)
            let method = try readLittleEndian(directoryEntryOffset + 10, 2)
            let checksum = try readLittleEndian(directoryEntryOffset + 16, 4)
            let compressedSize = try readLittleEndian(directoryEntryOffset + 20, 4)
            let expandedSize = try readLittleEndian(directoryEntryOffset + 24, 4)
            let nameLength = try readLittleEndian(directoryEntryOffset + 28, 2)
            let extraLength = try readLittleEndian(directoryEntryOffset + 30, 2)
            let commentLength = try readLittleEndian(directoryEntryOffset + 32, 2)
            let attributes = try readLittleEndian(directoryEntryOffset + 38, 4)
            let localHeaderOffset = try readLittleEndian(directoryEntryOffset + 42, 4)
            let nameStart = directoryEntryOffset + 46
            let nextEntryOffset = nameStart + nameLength + extraLength + commentLength
            guard nextEntryOffset <= endOfCentralDirectoryOffset, nameLength > 0,
                let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8),
                safePath(name), names.insert(name.lowercased()).inserted,
                flags & 0x2041 == 0, [0, 8].contains(method), expandedSize <= 1_048_576,
                (attributes >> 16) & 0xf000 != 0xa000, try readLittleEndian(directoryEntryOffset + 34, 2) == 0
            else { throw OpenVPNError.invalidArchive }
            totalExpandedSize += expandedSize
            guard totalExpandedSize <= 4 * 1024 * 1024, try readLittleEndian(localHeaderOffset, 4) == 0x0403_4b50,
                try readLittleEndian(localHeaderOffset + 6, 2) == flags,
                try readLittleEndian(localHeaderOffset + 8, 2) == method,
                try readLittleEndian(localHeaderOffset + 26, 2) == nameLength
            else { throw OpenVPNError.invalidArchive }
            let payloadOffset = localHeaderOffset + 30 + nameLength + (try readLittleEndian(localHeaderOffset + 28, 2))
            guard payloadOffset <= directoryEntryOffset, compressedSize <= directoryEntryOffset - payloadOffset,
                bytes[(localHeaderOffset + 30)..<(localHeaderOffset + 30 + nameLength)].elementsEqual(
                    bytes[nameStart..<(nameStart + nameLength)])
            else { throw OpenVPNError.invalidArchive }
            let payload = Array(bytes[payloadOffset..<(payloadOffset + compressedSize)])
            let output: [UInt8]
            if method == 0 {
                guard compressedSize == expandedSize else { throw OpenVPNError.invalidArchive }
                output = payload
            } else {
                var buffer = [UInt8](repeating: 0, count: max(1, expandedSize))
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
                else {
                    throw OpenVPNError.invalidArchive
                }
                defer { inflateEnd(&stream) }
                let status = payload.withUnsafeBytes { input in
                    buffer.withUnsafeMutableBytes { destination in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                        stream.avail_in = uInt(payload.count)
                        stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                        stream.avail_out = uInt(destination.count)
                        return inflate(&stream, Z_FINISH)
                    }
                }
                guard status == Z_STREAM_END, stream.total_out == expandedSize, stream.total_in == compressedSize else {
                    throw OpenVPNError.invalidArchive
                }
                output = Array(buffer.prefix(expandedSize))
            }
            let actualChecksum = output.withUnsafeBytes {
                crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))
            }
            guard actualChecksum == checksum else { throw OpenVPNError.invalidArchive }
            if !name.hasSuffix("/") { result[name] = Data(output) }
            directoryEntryOffset = nextEntryOffset
        }
        guard directoryEntryOffset == endOfCentralDirectoryOffset else { throw OpenVPNError.invalidArchive }
        return result
    }

    static func safePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: { $0.value < 32 })
            && !parts.dropLast().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && parts.last != "." && parts.last != ".."
    }
}
