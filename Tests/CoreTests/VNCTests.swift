import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

final class VNCTests: XCTestCase {
    @MainActor func testVNCProfilePreservesExistingMetadataAndReopens() throws {
        var draft = ConnectionDraft()
        draft.kind = .vnc
        draft.host = "fixture.invalid"
        draft.port = RemoteProtocol.vnc.defaultPort
        draft.username = ""
        draft.wireGuardID = UUID()
        draft.displayMode = .actualSize
        draft.launchFullScreen = true
        XCTAssertNil(draft.validationMessage)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.store")
        let config = ModelConfiguration(url: url)
        do {
            let container = try ModelContainer(for: SavedConnection.self, configurations: config)
            container.mainContext.insert(SavedConnection(draft: draft))
            var ssh = ConnectionDraft()
            ssh.host = "ssh.fixture.invalid"
            ssh.username = "fixture"
            container.mainContext.insert(SavedConnection(draft: ssh))
            try container.mainContext.save()
        }
        let reopened = try ModelContainer(for: SavedConnection.self, configurations: config)
        let profiles = try reopened.mainContext.fetch(FetchDescriptor<SavedConnection>())
        XCTAssertEqual(profiles.count, 2)
        let restored = ConnectionDraft(try XCTUnwrap(profiles.first { $0.id == draft.id }))
        XCTAssertEqual(restored.kind, .vnc)
        XCTAssertEqual(restored.port, 5900)
        XCTAssertEqual(restored.wireGuardID, draft.wireGuardID)
        XCTAssertEqual(restored.displayMode, .actualSize)
        XCTAssertTrue(restored.launchFullScreen)
        XCTAssertNil(restored.validationMessage)
        XCTAssertEqual(profiles.first { $0.kind == .ssh }?.username, "fixture")
        XCTAssertNotEqual(restored.endpointKey, "RDP|fixture.invalid|5900")
    }
    func testVNCValidationAndKeySymbols() {
        var draft = ConnectionDraft()
        draft.kind = .vnc
        draft.host = "fixture.invalid"
        draft.port = 5900
        XCTAssertNil(draft.validationMessage)
        draft.port = 0
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x1E, extended: false), 97)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x1D, extended: false), 0xFFE3)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x38, extended: false), 0xFFE9)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x53, extended: true), 0xFFFF)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x3B, extended: false), 0xFFBE)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x58, extended: false), 0xFFC9)
        XCTAssertNil(VNCKeyboard.keySym(scanCode: 0x7FFF, extended: false))
    }
}
