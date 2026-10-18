import Foundation
import zlib

/// Small, in-memory ZIP reader for user-selected VPN bundles. Never extracts paths.
struct BoundedZIP {
    static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func number(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - count else { throw OpenVPNError.invalidArchive }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
        }
        guard bytes.count >= 22, bytes.count <= 4 * 1024 * 1024 else { throw OpenVPNError.invalidArchive }
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try number(offset, 4) == 0x0605_4b50,
                offset + 22 + (try number(offset + 20, 2)) == bytes.count
            {
                end = offset
                break
            }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else {
            throw OpenVPNError.invalidArchive
        }
        let count = try number(end + 10, 2)
        let size = try number(end + 12, 4)
        var cursor = try number(end + 16, 4)
        guard (1...64).contains(count), try number(end + 8, 2) == count, cursor + size == end else {
            throw OpenVPNError.invalidArchive
        }
        var result: [String: Data] = [:]
        var names = Set<String>()
        var total = 0
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x0201_4b50 else { throw OpenVPNError.invalidArchive }
            let flags = try number(cursor + 8, 2)
            let method = try number(cursor + 10, 2)
            let checksum = try number(cursor + 16, 4)
            let compressed = try number(cursor + 20, 4)
            let expanded = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2)
            let extraLength = try number(cursor + 30, 2)
            let commentLength = try number(cursor + 32, 2)
            let attributes = try number(cursor + 38, 4)
            let local = try number(cursor + 42, 4)
            let nameStart = cursor + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= end, nameLength > 0,
                let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8),
                safePath(name), names.insert(name.lowercased()).inserted,
                flags & 0x2041 == 0, [0, 8].contains(method), expanded <= 1_048_576,
                (attributes >> 16) & 0xf000 != 0xa000, try number(cursor + 34, 2) == 0
            else { throw OpenVPNError.invalidArchive }
            total += expanded
            guard total <= 4 * 1024 * 1024, try number(local, 4) == 0x0403_4b50,
                try number(local + 6, 2) == flags, try number(local + 8, 2) == method,
                try number(local + 26, 2) == nameLength
            else { throw OpenVPNError.invalidArchive }
            let start = local + 30 + nameLength + (try number(local + 28, 2))
            guard start <= cursor, compressed <= cursor - start,
                bytes[(local + 30)..<(local + 30 + nameLength)].elementsEqual(
                    bytes[nameStart..<(nameStart + nameLength)])
            else { throw OpenVPNError.invalidArchive }
            let payload = Array(bytes[start..<(start + compressed)])
            let output: [UInt8]
            if method == 0 {
                guard compressed == expanded else { throw OpenVPNError.invalidArchive }
                output = payload
            } else {
                var buffer = [UInt8](repeating: 0, count: max(1, expanded))
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
                guard status == Z_STREAM_END, stream.total_out == expanded, stream.total_in == compressed else {
                    throw OpenVPNError.invalidArchive
                }
                output = Array(buffer.prefix(expanded))
            }
            let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
            guard crc == checksum else { throw OpenVPNError.invalidArchive }
            if !name.hasSuffix("/") { result[name] = Data(output) }
            cursor = next
        }
        guard cursor == end else { throw OpenVPNError.invalidArchive }
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
