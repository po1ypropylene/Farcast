import CoreGraphics
import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

final class RDPDisplayTests: XCTestCase {
    func screen(_ id: UInt32, _ x: Double, _ y: Double, _ width: Double, _ height: Double, scale: Double = 1)
        -> RDPDisplayScreen
    {
        .init(id: id, frame: CGRect(x: x, y: y, width: width, height: height), backingScale: scale)
    }
    func testLeftAbovePortraitAndDifferentPrimary() throws {
        let layout = try RDPDisplayLayout(
            screens: [
                screen(4, 500, 400, 1440, 900), screen(2, -580, 400, 1080, 1920), screen(3, 500, 1300, 1440, 900),
            ], retina: false)
        XCTAssertEqual(layout.monitors[0].rect, CGRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(layout.monitors[1].rect, CGRect(x: -1080, y: -1020, width: 1080, height: 1920))
        XCTAssertEqual(layout.monitors[2].rect, CGRect(x: 0, y: -900, width: 1440, height: 900))
        XCTAssertEqual(layout.sourceRect(for: layout.monitors[0]).origin, CGPoint(x: 1080, y: 1020))
        XCTAssertTrue(layout.monitors[0].primary)
        XCTAssertEqual(layout.bounds.size, CGSize(width: 2520, height: 1920))
    }
    func testMixedBackingRepositionsNeighborsAndKeepsDistinctDPI() throws {
        let screens = [
            screen(1, 0, 0, 1440, 900, scale: 2), screen(2, 1440, 0, 1920, 1080), screen(3, -1080, 0, 1080, 1920),
        ]
        let layout = try RDPDisplayLayout(screens: screens, retina: true)
        XCTAssertEqual(layout.monitors[0].rect.size, CGSize(width: 2880, height: 1800))
        XCTAssertEqual(layout.monitors[1].rect.minX, 2880)
        XCTAssertEqual(layout.monitors[2].rect.maxX, 0)
        XCTAssertEqual(layout.monitors.map(\.desktopScale), [200, 100, 100])
        for monitor in layout.monitors { XCTAssertTrue(layout.bounds.contains(monitor.rect)) }
    }
    func testWideThreeDisplayLayoutFitsBoundedPixelBudget() throws {
        let layout = try RDPDisplayLayout(
            screens: [
                screen(1, 0, 0, 2560, 1440, scale: 2),
                screen(2, 2560, 0, 2560, 1440, scale: 2),
                screen(3, 5120, 0, 2560, 1440, scale: 2),
            ], retina: true)
        XCTAssertEqual(layout.bounds.size, CGSize(width: 15360, height: 2880))
        XCTAssertEqual(layout.monitors.map { $0.rect.minX }, [0, 5120, 10240])
    }
    func testInvalidTopologyScaleBoundsAndDuplicates() {
        let invalid: [[RDPDisplayScreen]] = [
            [], [screen(1, 0, 0, 100, 900)],
            [screen(1, 0, 0, 1440, 900, scale: .nan)],
            [screen(1, 0, 0, 1440, 900), screen(1, 1440, 0, 1440, 900)],
            [screen(1, 0, 0, 1440, 900), screen(2, 1000, 0, 1440, 900)],
            [screen(1, 0, 0, 1440, 900), screen(2, 1500, 0, 1440, 900)],
            [screen(1, 0, 0, 5000, 3000, scale: 2)],
            [screen(1, 0, 0, 8192, 8192), screen(2, 8192, 0, 8192, 8192)],
        ]
        for screens in invalid { XCTAssertThrowsError(try RDPDisplayLayout(screens: screens, retina: true)) }
        XCTAssertThrowsError(
            try RDPDisplayLayout(
                screens: (0...16).map { screen(UInt32($0), Double($0) * 200, 0, 200, 200) }, retina: false))
    }
    func testEvenWidthAndCornerContact() throws {
        let layout = try RDPDisplayLayout(
            screens: [screen(1, 0, 0, 1441, 901), screen(2, 1441, 901, 641, 481)], retina: false)
        XCTAssertEqual(layout.monitors.map { $0.rect.width }, [1440, 640])
        XCTAssertEqual(layout.monitors[1].rect, CGRect(x: 1440, y: -481, width: 640, height: 481))
    }
    func testInputInverseIncludesCropYFlipAndRejectsPadding() {
        let t = RDPDisplayTransform(
            source: CGRect(x: 2880, y: 100, width: 1920, height: 1080),
            destination: CGRect(x: 0, y: 90, width: 960, height: 540))
        XCTAssertEqual(t.remotePoint(local: CGPoint(x: 480, y: 360), viewHeight: 720), CGPoint(x: 3840, y: 640))
        XCTAssertEqual(t.remotePoint(local: CGPoint(x: 960, y: 90), viewHeight: 720), CGPoint(x: 4799, y: 1179))
        XCTAssertNil(t.remotePoint(local: CGPoint(x: 10, y: 700), viewHeight: 720))
        XCTAssertNil(t.remotePoint(local: CGPoint(x: 1000, y: 400), viewHeight: 720))
        XCTAssertNil(RDPDisplayTransform(source: .zero, destination: .zero).remotePoint(local: .zero, viewHeight: 0))
    }
    @MainActor func testDisplaySettingsRoundTripAndMissingFieldsPreserveDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([SavedConnection.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("store"))
        let container = try ModelContainer(for: schema, configurations: config)
        var draft = ConnectionDraft()
        draft.host = "fixture.invalid"
        draft.username = "fixture"
        draft.kind = .rdp
        draft.launchFullScreen = true
        draft.useAllMonitors = true
        draft.retinaDisplay = true
        draft.desktopWidth = 1234
        draft.desktopHeight = 777
        let saved = SavedConnection(draft: draft)
        container.mainContext.insert(saved)
        try container.mainContext.save()
        let reopened = try ModelContainer(for: schema, configurations: config)
        let profile = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<SavedConnection>()).first)
        let loaded = ConnectionDraft(profile)
        XCTAssertTrue(loaded.launchFullScreen && loaded.useAllMonitors && loaded.retinaDisplay)
        XCTAssertEqual(loaded.desktopWidth, 1234)
        XCTAssertEqual(loaded.desktopHeight, 777)
        profile.rdpLaunchFullScreen = nil
        profile.rdpUseAllMonitors = nil
        profile.rdpRetinaDisplay = nil
        let old = ConnectionDraft(profile)
        XCTAssertFalse(old.launchFullScreen || old.useAllMonitors || old.retinaDisplay)
        XCTAssertEqual(old.id, draft.id)
        XCTAssertEqual(old.desktopWidth, 1234)
    }
}
