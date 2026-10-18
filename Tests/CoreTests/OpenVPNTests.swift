import Foundation
import XCTest

@testable import FarcastCore

final class OpenVPNTests: XCTestCase {
    private let profile = """
        client
        dev tun
        proto udp
        remote vpn.example.invalid 1194
        auth-user-pass
        <ca>
        synthetic-ca
        </ca>
        """

    func testImportAddsServerPurposeAndRequiresPassword() throws {
        let parsed = try OpenVPNImport.parse(Data(profile.utf8))
        XCTAssertTrue(parsed.requiresPassword)
        XCTAssertTrue(parsed.profile.contains("remote-cert-tls server"))
        XCTAssertEqual(try OpenVPNImport.parse(Data(parsed.profile.utf8)).profile, parsed.profile)
    }

    func testUnsafeAndUnsupportedOptionsFailClosed() {
        for option in [
            "up /tmp/script", "plugin plugin.dylib", "config other.ovpn", "ca ca.pem",
            "auth-user-pass passwords.txt", "remote-cert-tls client", "tls-version-min 1.0",
            "dev tap", "compress lz4", "http-proxy example.invalid 8080", "management 127.0.0.1 5555",
            "<connection>\nremote alternate.invalid\n</connection>",
        ] {
            XCTAssertThrowsError(try OpenVPNImport.parse(Data((profile + "\n" + option).utf8)))
        }
        XCTAssertThrowsError(try OpenVPNImport.parse(Data(repeating: 65, count: 262_145)))
        XCTAssertThrowsError(try OpenVPNImport.parse(Data((profile + "\n<key>\nincomplete").utf8)))
        XCTAssertThrowsError(
            try OpenVPNImport.parse(Data(profile.replacingOccurrences(of: "<ca>", with: "<unknown>").utf8)))
    }

    func testCertificateProfileAndQuotedRemote() throws {
        let input =
            profile.replacingOccurrences(of: "auth-user-pass", with: "")
            .replacingOccurrences(of: "vpn.example.invalid", with: "\"vpn.example.invalid\"")
            + "\n<cert>\nsynthetic-cert\n</cert>\n<key>\nsynthetic-key\n</key>"
        XCTAssertFalse(try OpenVPNImport.parse(Data(input.utf8)).requiresPassword)
    }

    func testOldMetadataAndCredentialCompatibility() throws {
        var old = WireGuardConfiguration()
        let oldData = try JSONEncoder().encode(old)
        XCTAssertFalse(try JSONDecoder().decode(WireGuardConfiguration.self, from: oldData).isOpenVPN)
        old.openVPN = true
        let saved = try SavedWireGuard(name: "Test OpenVPN", configuration: old)
        XCTAssertTrue(try saved.configuration().isOpenVPN)
        XCTAssertFalse(String(decoding: saved.configurationData, as: UTF8.self).contains("synthetic-ca"))
        let credential = ConnectionCredential(
            password: "synthetic-password", openVPNProfile: profile,
            openVPNUsername: "synthetic-user", openVPNPassphrase: "synthetic-passphrase")
        let decoded = try JSONDecoder().decode(ConnectionCredential.self, from: JSONEncoder().encode(credential))
        XCTAssertEqual(decoded.openVPNProfile, profile)
        XCTAssertEqual(decoded.openVPNPassphrase, credential.openVPNPassphrase)
        let oldCredential = try JSONDecoder().decode(ConnectionCredential.self, from: Data("{\"password\":\"\"}".utf8))
        XCTAssertNil(oldCredential.openVPNProfile)
    }
}
