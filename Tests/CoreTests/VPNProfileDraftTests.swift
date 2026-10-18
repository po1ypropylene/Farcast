import Foundation
import XCTest

@testable import FarcastCore

final class VPNProfileDraftTests: XCTestCase {
    private func validDraft() -> VPNProfileDraft {
        var draft = VPNProfileDraft()
        draft.configuration.addresses = "10.0.0.2/32, fd00::2/128"
        draft.configuration.endpoint = "[::1]:51820"
        draft.configuration.allowedIPs = "0.0.0.0/0, ::/0"
        draft.privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        draft.configuration.publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        return draft
    }

    func testFieldErrorsAndRawNumericEdits() {
        var draft = validDraft()
        XCTAssertTrue(draft.issues(existingNames: []).isEmpty)
        draft.name = "  existing  "
        draft.mtu = "invalid"
        draft.keepalive = "-1"
        draft.configuration.addresses = "10.0.0.2"
        draft.configuration.endpoint = "host.invalid:65536"
        draft.presharedKey = "bad"
        let issues = draft.issues(existingNames: ["EXISTING"])
        XCTAssertEqual(Set(issues.keys), ["name", "mtu", "keepalive", "address", "endpoint", "presharedKey"])
        XCTAssertEqual(draft.mtu, "invalid", "Invalid numeric input stays editable rather than reverting silently")
    }

    func testEngineBoundsAndOptionalFields() {
        var draft = validDraft()
        for mtu in ["1280", "1420", "1500"] {
            draft.mtu = mtu
            XCTAssertNil(draft.issues(existingNames: [])["mtu"])
        }
        for mtu in ["576", "1279", "1501", "1420x", ""] {
            draft.mtu = mtu
            XCTAssertNotNil(draft.issues(existingNames: [])["mtu"])
        }
        draft.mtu = "1420"
        draft.configuration.dns = "not-an-ip"
        XCTAssertNotNil(draft.issues(existingNames: [])["dns"])
        draft.configuration.dns = ""
        XCTAssertTrue(draft.issues(existingNames: []).isEmpty)
    }

    func testOpenVPNRequiresImportAndConditionalAuthentication() throws {
        var draft = VPNProfileDraft()
        draft.configuration.openVPN = true
        XCTAssertEqual(Set(draft.issues(existingNames: []).keys), ["import"])
        draft.openVPNProfile = "client\ndev tun\nremote vpn.example.invalid\nauth-user-pass\n<ca>\nsynthetic\n</ca>\n"
        XCTAssertEqual(Set(draft.issues(existingNames: []).keys), ["username", "password"])
        draft.username = "synthetic"
        draft.password = "synthetic"
        XCTAssertTrue(draft.issues(existingNames: []).isEmpty)
        let parsed = try OpenVPNImport.parse(Data(draft.openVPNProfile.utf8))
        XCTAssertEqual(parsed.summary, "UDP · 1194 · vpn.example.invalid")
        draft.openVPNProfile += "proto tcp-client\n"
        XCTAssertEqual(
            try OpenVPNImport.parse(Data(draft.openVPNProfile.utf8)).summary, "TCP · 1194 · vpn.example.invalid")
    }

    func testSummaryIgnoresSecretBlocksAndUsesRemoteTransport() throws {
        let profile = """
            client
            dev tun
            proto udp
            remote "vpn.example.invalid" 443 tcp-client
            auth-user-pass
            <ca>
            remote secret.invalid 9999
            proto udp
            </ca>
            """
        XCTAssertEqual(try OpenVPNImport.parse(Data(profile.utf8)).summary, "TCP · 443 · vpn.example.invalid")
    }
}
