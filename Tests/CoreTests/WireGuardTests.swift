import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

final class WireGuardTests: XCTestCase {
    private var fixture: String {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        return """
            [Interface]
            PrivateKey = \(key)
            Address = 10.111.0.2/32, fd00::2/128
            DNS = 10.111.0.1
            MTU = 1420
            [Peer]
            PublicKey = \(key)
            PresharedKey = \(key)
            Endpoint = [::1]:51820
            AllowedIPs = 10.111.0.0/24, fd00::/64
            PersistentKeepalive = 25
            """
    }
    func testImportAndSecretSeparation() throws {
        let imported = try WireGuardImport.parse(Data(fixture.utf8))
        XCTAssertNil(imported.configuration.validationMessage)
        XCTAssertEqual(imported.configuration.endpoint, "[::1]:51820")
        let metadata = String(decoding: try JSONEncoder().encode(imported.configuration), as: UTF8.self)
        XCTAssertFalse(metadata.contains("privateKey"))
        XCTAssertFalse(metadata.contains("presharedKey"))
        let secret = ConnectionCredential(
            wireGuardPrivateKey: imported.privateKey, wireGuardPresharedKey: imported.presharedKey)
        let restored = try JSONDecoder().decode(ConnectionCredential.self, from: JSONEncoder().encode(secret))
        XCTAssertEqual(restored.wireGuardPrivateKey, imported.privateKey)
        XCTAssertEqual(restored.wireGuardPresharedKey, imported.presharedKey)
        let oldCredential = try JSONDecoder().decode(
            ConnectionCredential.self, from: Data("{\"password\":\"synthetic\"}".utf8))
        XCTAssertNil(oldCredential.wireGuardPrivateKey)
    }
    func testRejectUnsafeAndAmbiguousImportsWithoutEchoingContents() {
        for text in [
            fixture + "\n[Peer]\n", fixture + "\nPostUp = synthetic-sensitive-value\n",
            fixture.replacingOccurrences(of: "MTU = 1420", with: "MTU = invalid"),
            fixture.replacingOccurrences(of: "PrivateKey =", with: "UnexpectedKey ="),
            fixture.replacingOccurrences(of: "10.111.0.2/32", with: "10.111.0.2/99"),
            fixture + "\nEndpoint = other.example:51820",
        ] {
            XCTAssertThrowsError(try WireGuardImport.parse(Data(text.utf8))) { error in
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-value"))
            }
        }
        XCTAssertThrowsError(try WireGuardImport.parse(Data(repeating: 65, count: 65_537)))
    }
    func testValidationOfEndpointAddressesAndOptions() throws {
        var configuration = try WireGuardImport.parse(Data(fixture.utf8)).configuration
        for endpoint in [
            "vpn.example", "vpn.example:0", "vpn.example:65536", "vpn.example:51820/path", "user@vpn.example:51820",
            "vpn.example:51820?arg=x",
        ] {
            configuration.endpoint = endpoint
            XCTAssertNotNil(configuration.validationMessage)
        }
        configuration.endpoint = "vpn.example:51820"
        XCTAssertNil(configuration.validationMessage)
        configuration.keepalive = -1
        XCTAssertNotNil(configuration.validationMessage)
        configuration.keepalive = 0
        configuration.mtu = 1279
        XCTAssertNotNil(configuration.validationMessage)
    }
    @MainActor func testWireGuardSelectionPersistsAcrossProtocolsAndDeletionDoesNotEnableDirect() throws {
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tunnel = try SavedWireGuard(
            name: "Synthetic tunnel", configuration: WireGuardImport.parse(Data(fixture.utf8)).configuration)
        container.mainContext.insert(tunnel)
        var connections: [SavedConnection] = []
        for kind in RemoteProtocol.allCases {
            var draft = ConnectionDraft()
            draft.host = "10.111.0.1"
            draft.username = "fixture"
            draft.kind = kind
            draft.port = kind == .ssh ? 22 : 3389
            draft.wireGuardID = tunnel.id
            let connection = SavedConnection(draft: draft)
            connections.append(connection)
            container.mainContext.insert(connection)
        }
        try container.mainContext.save()
        for connection in connections { XCTAssertEqual(ConnectionDraft(connection).wireGuardID, tunnel.id) }
        container.mainContext.delete(tunnel)
        try container.mainContext.save()
        for connection in connections { XCTAssertEqual(ConnectionDraft(connection).wireGuardID, tunnel.id) }
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<SavedWireGuard>()).isEmpty)
        let names = schema.entities.first { $0.name == "SavedWireGuard" }!.properties.map(\.name)
        XCTAssertFalse(names.contains("privateKey"))
        XCTAssertFalse(names.contains("presharedKey"))
    }
    func testStartupDiagnosticsAreSpecificAndRedacted() throws {
        let ready = try JSONDecoder().decode(WireGuardStartupResponse.self, from: Data("{\"port\":45678}".utf8))
        XCTAssertEqual(try ready.listenerPort(), 45678)
        for (code, expected) in [
            ("endpoint_resolution", WireGuardError.endpointResolution), ("configuration", .invalidConfiguration),
            ("listener", .listener), ("synthetic-sensitive-content", .initialization),
        ] {
            let response = WireGuardStartupResponse(error: code)
            XCTAssertThrowsError(try response.listenerPort()) { error in
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-sensitive-content"))
            }
        }
        XCTAssertThrowsError(try WireGuardStartupResponse(port: 0).listenerPort())
        XCTAssertThrowsError(try WireGuardStartupResponse(port: 65536).listenerPort())
    }

}
