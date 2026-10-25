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
    @MainActor func testMacVNCOptInPersistenceValidationAndSeparateIdentity() throws {
        var draft = ConnectionDraft()
        draft.kind = .vnc
        draft.host = "fixture.invalid"
        draft.port = 5900
        let standard = SavedConnection(draft: draft)
        standard.vncRemoteIsMac = nil
        XCTAssertFalse(ConnectionDraft(standard).vncRemoteIsMac)
        let standardEndpoint = draft.endpointKey
        draft.vncRemoteIsMac = true
        XCTAssertNotNil(draft.validationMessage)
        draft.username = "fixture"
        draft.dynamicResolution = true
        draft.displayMode = .actualSize
        XCTAssertEqual(draft.effectiveDisplayMode, .fit)
        XCTAssertNil(draft.validationMessage)
        XCTAssertNotEqual(draft.endpointKey, standardEndpoint)
        draft.retinaDisplay = true
        draft.desktopWidth = 1920
        draft.desktopHeight = 1080
        XCTAssertNil(draft.validationMessage)
        draft.desktopWidth = 1921
        XCTAssertNotNil(draft.validationMessage)
        draft.desktopWidth = 1440
        let saved = SavedConnection(draft: draft)
        let container = try ModelContainer(
            for: SavedConnection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container.mainContext.insert(saved)
        try container.mainContext.save()
        let duplicate = saved.duplicate()
        XCTAssertTrue(ConnectionDraft(duplicate).vncRemoteIsMac)
        XCTAssertTrue(ConnectionDraft(saved).retinaDisplay)
        saved.update(from: ConnectionDraft(standard))
        XCTAssertFalse(ConnectionDraft(saved).vncRemoteIsMac)
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
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x5D, extended: true), 0xFF67)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x45, extended: false), 0xFF7F)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x46, extended: false), 0xFF14)
        XCTAssertEqual(VNCKeyboard.keySym(scanCode: 0x37, extended: true), 0xFF61)
        for (characters, expected) in [
            ("\u{F730}", UInt32(0xFF13)), ("\u{F72E}", 0xFF61),
            ("\u{F72F}", 0xFF14), ("\u{F735}", 0xFF67), ("\u{F745}", 0xFF68),
        ] {
            XCTAssertEqual(VNCKeyboard.keySym(keyCode: 0, characters: characters), expected)
        }
        for scalar in UInt32(0xF704)...0xF726 {
            XCTAssertEqual(
                VNCKeyboard.keySym(keyCode: 0, characters: String(Unicode.Scalar(scalar)!)),
                0xFFBE + scalar - 0xF704)
        }
        XCTAssertEqual(VNCKeyboard.keySym(keyCode: 102, characters: ""), 0xFF30)
        XCTAssertEqual(VNCKeyboard.keySym(keyCode: 104, characters: ""), 0xFF27)
        XCTAssertEqual(VNCKeyboard.keySym(keyCode: 0, characters: "é"), 0xE9)
        XCTAssertEqual(VNCKeyboard.keySym(keyCode: 0, characters: "Ж"), 0x0100_0416)
        XCTAssertEqual(VNCKeyboard.keySym(keyCode: 0, characters: "q"), 0x71)  // AZERTY physical A position.
        XCTAssertNil(VNCKeyboard.keySym(keyCode: 0, characters: ""))
        XCTAssertNil(VNCKeyboard.keySym(scanCode: 0x7FFF, extended: false))
    }
}
