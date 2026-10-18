import Foundation
import XCTest
import zlib

@testable import FarcastCore

final class OpenVPNBundleTests: XCTestCase {
    private let config = "client\ndev tun\nremote example.invalid 1194\nca ca.crt\ncert client.crt\nkey client.key\n"
    private var files: [String: Data] {
        [
            "client.conf": Data(config.utf8), "ca.crt": Data("synthetic CA".utf8),
            "client.crt": Data("synthetic certificate".utf8), "client.key": Data("synthetic private key".utf8),
        ]
    }
    func testZIPAndFolderResolveCompanionsWithoutExtracting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, data) in files { try data.write(to: root.appendingPathComponent(name)) }
        let folder = try OpenVPNBundleReader.read(root)
        XCTAssertTrue(folder.missingFiles.isEmpty)
        XCTAssertTrue(try folder.assemble().profile.contains("<key>\nsynthetic private key"))
        let zip = root.appendingPathComponent("bundle.zip")
        try archive(files).write(to: zip)
        let zipped = try OpenVPNBundleReader.read(zip)
        XCTAssertEqual(try zipped.assemble().profile, try folder.assemble().profile)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 5)
    }
    func testManualFileSelectionAndNoImplicitSiblingAccess() throws {
        var document = try OpenVPNImportDocument(data: Data(config.utf8))
        XCTAssertEqual(Set(document.missingFiles), Set([.ca, .cert, .key]))
        XCTAssertThrowsError(try document.assemble())
        document.files = [.ca: files["ca.crt"]!, .cert: files["client.crt"]!, .key: files["client.key"]!]
        XCTAssertNotNil(try document.assemble())
        document.files[.key] = Data("</key>\nup malicious".utf8)
        XCTAssertThrowsError(try document.assemble())
    }
    func testTAPAndCompressionAreExplicit() throws {
        let tap = try OpenVPNImportDocument(
            data: Data(config.replacingOccurrences(of: "dev tun", with: "dev tap").utf8), resources: files)
        XCTAssertTrue(tap.isTAP)
        XCTAssertThrowsError(try tap.assemble()) { XCTAssertTrue($0 is OpenVPNError) }
        var compressed = try OpenVPNImportDocument(data: Data((config + "comp-lzo\n").utf8), resources: files)
        XCTAssertTrue(compressed.needsLegacyCompression)
        XCTAssertThrowsError(try compressed.assemble())
        compressed.allowLegacyCompression = true
        let profile = try compressed.assemble().profile
        XCTAssertTrue(profile.contains("setenv FARCAST_LEGACY_COMPRESSION 1"))
        let reimported = try OpenVPNImportDocument(data: Data(profile.utf8))
        XCTAssertFalse(reimported.allowLegacyCompression)
        XCTAssertThrowsError(try reimported.assemble())
        XCTAssertNotNil(try OpenVPNImport.parse(Data(profile.utf8)))
        XCTAssertThrowsError(try OpenVPNImport.parse(Data((profile + "up script.sh\n").utf8)))
    }
    func testArchiveRejectsTraversalDuplicateSymlinkCorruptionAndLimits() throws {
        for path in ["../secret", "/absolute", "a/../secret", "a\\secret", "a//secret"] {
            XCTAssertThrowsError(try BoundedZIP.read(archive([path: Data("x".utf8)])))
        }
        XCTAssertThrowsError(try BoundedZIP.read(archive(["a": Data(), "A": Data()])))
        var symlink = archive(["link": Data("target".utf8)])
        let central = firstSignature(in: symlink, value: [0x50, 0x4b, 0x01, 0x02])
        symlink[central + 41] = 0xa0
        XCTAssertThrowsError(try BoundedZIP.read(symlink))
        var corrupt = archive(["a": Data("payload".utf8)])
        corrupt[31] ^= 1
        XCTAssertThrowsError(try BoundedZIP.read(corrupt))
        XCTAssertThrowsError(try BoundedZIP.read(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try BoundedZIP.read(Data(archive(files).dropLast())))
    }
    func testFolderRejectsLinksAndMultipleConfigurations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, data) in files { try data.write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("alias").path, withDestinationPath: "ca.crt")
        XCTAssertThrowsError(try OpenVPNBundleReader.read(root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("alias"))
        try Data(config.utf8).write(to: root.appendingPathComponent("second.ovpn"))
        XCTAssertThrowsError(try OpenVPNBundleReader.read(root))
    }
    func testDeflatedArchive() throws {
        let archive = Data(
            base64Encoded:
                "UEsDBBQAAAAIAOp6Ul0J1VhPEQAAAA8AAAAMAAAAZXhhbXBsZS5jb25mS87JTM0r4UpJLVMoKc3jAgBQSwECFAMUAAAACADqelJdCdVYTxEAAAAPAAAADAAAAAAAAAAAAAAAgAEAAAAAZXhhbXBsZS5jb25mUEsFBgAAAAABAAEAOgAAADsAAAAAAA=="
        )!
        XCTAssertEqual(try BoundedZIP.read(archive)["example.conf"], Data("client\ndev tun\n".utf8))
    }
    private func firstSignature(in data: Data, value: [UInt8]) -> Int {
        (0...(data.count - value.count)).first { Array(data[$0..<($0 + value.count)]) == value }!
    }
    private func archive(_ entries: [String: Data]) -> Data {
        var result = Data()
        var central = Data()
        func put(_ number: Int, _ size: Int, into data: inout Data) {
            for index in 0..<size { data.append(UInt8(truncatingIfNeeded: number >> (8 * index))) }
        }
        for name in entries.keys.sorted() {
            let body = entries[name]!
            let nameData = Data(name.utf8)
            let offset = result.count
            let crc = body.withUnsafeBytes { Int(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count))) }
            for (n, s) in [
                (0x0403_4b50, 4), (20, 2), (0, 2), (0, 2), (0, 2), (0, 2), (crc, 4), (body.count, 4), (body.count, 4),
                (nameData.count, 2), (0, 2),
            ] { put(n, s, into: &result) }
            result.append(nameData)
            result.append(body)
            for (n, s) in [
                (0x0201_4b50, 4), (20, 2), (20, 2), (0, 2), (0, 2), (0, 2), (0, 2), (crc, 4), (body.count, 4),
                (body.count, 4), (nameData.count, 2), (0, 2), (0, 2), (0, 2), (0, 2), (0, 4), (offset, 4),
            ] { put(n, s, into: &central) }
            central.append(nameData)
        }
        let offset = result.count
        result.append(central)
        for (n, s) in [
            (0x0605_4b50, 4), (0, 2), (0, 2), (entries.count, 2), (entries.count, 2), (central.count, 4), (offset, 4),
            (0, 2),
        ] { put(n, s, into: &result) }
        return result
    }
}
