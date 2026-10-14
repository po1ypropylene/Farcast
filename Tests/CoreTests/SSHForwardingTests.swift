import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

final class SSHForwardingTests: XCTestCase {
    func testRuleValidationAndLimits() {
        var rule = SSHForwardingRule()
        XCTAssertNotNil(rule.validationMessage)
        rule.destinationPort = 5432
        XCTAssertNil(rule.validationMessage)
        rule.bindAddress = "0.0.0.0"
        XCTAssertNotNil(rule.validationMessage)
        rule.kind = .remote
        XCTAssertNil(rule.validationMessage)
        rule.bindAddress = "::1"
        rule.destinationHost = "2001:db8::1"
        XCTAssertNil(rule.validationMessage)
        rule.destinationHost = "server:443"
        XCTAssertNotNil(rule.validationMessage)
        rule.destinationHost = "server\0invalid"
        XCTAssertNotNil(rule.validationMessage)
        rule.kind = .socks
        XCTAssertNil(rule.validationMessage)
        rule.bindPort = -1
        XCTAssertNotNil(rule.validationMessage)
        rule.bindPort = 65536
        XCTAssertNotNil(rule.validationMessage)
        rule.bindPort = 0
        var draft = ConnectionDraft()
        draft.host = "fixture.example"
        draft.username = "fixture"
        draft.forwardingRules = [rule, rule]
        XCTAssertNotNil(draft.validationMessage)
        draft.forwardingRules = (0..<17).map { _ in SSHForwardingRule(kind: .socks) }
        XCTAssertNotNil(draft.validationMessage)
        draft.forwardingRules = [rule]
        XCTAssertNil(draft.validationMessage)
    }
    func testNewTunnelStartsWithEmptyDestinationAndExplicitAutoPresentation() {
        let rule = SSHForwardingRule.newRule()
        XCTAssertEqual(rule.destinationHost, "")
        XCTAssertEqual(rule.destinationPort, 0)
        XCTAssertEqual(rule.displayListener, "127.0.0.1:Auto")
        XCTAssertNotNil(rule.validationMessage(for: .destinationHost))
        XCTAssertNotNil(rule.validationMessage(for: .destinationPort))
        XCTAssertNil(rule.validationMessage(for: .listenPort))
        XCTAssertFalse(rule.exposesListener)
        var remote = rule
        remote.kind = .remote
        remote.bindAddress = "0.0.0.0"
        XCTAssertTrue(remote.exposesListener)
    }
    func testQuickConnectAddressParsing() throws {
        let ssh = try QuickConnectAddress.parse("user@fixture.invalid:2222", defaultKind: .ssh)
        XCTAssertEqual(ssh.host, "fixture.invalid")
        XCTAssertEqual(ssh.port, 2222)
        XCTAssertEqual(ssh.username, "user")
        let rdp = try QuickConnectAddress.parse("rdp://user@[2001:db8::1]:3390", defaultKind: .ssh)
        XCTAssertEqual(rdp.kind, .rdp)
        XCTAssertEqual(rdp.host, "2001:db8::1")
        XCTAssertEqual(rdp.port, 3390)
        XCTAssertEqual(try QuickConnectAddress.parse("fixture.invalid", defaultKind: .vnc).port, 5900)
        for invalid in [
            "ssh://user:password@fixture.invalid", "http://fixture.invalid", "ssh://fixture.invalid:0",
            "ssh://fixture.invalid/path", "ssh://fixture.invalid?secret=value", "bad host", "fixture.invalid:invalid",
        ] {
            XCTAssertThrowsError(try QuickConnectAddress.parse(invalid, defaultKind: .ssh))
        }
    }
    @MainActor func testDuplicatePreservesEverySettingWithoutCredentialIdentity() throws {
        var original = ConnectionDraft()
        original.name = "Fixture"
        original.host = "fixture.invalid"
        original.port = 2222
        original.username = "fixture-user"
        original.domain = "fixture-domain"
        original.authentication = .privateKey
        original.folderID = UUID()
        original.favorite = true
        original.notes = "Fixture notes"
        original.fontSize = 19
        original.terminalTheme = "Paper"
        original.desktopWidth = 1600
        original.desktopHeight = 1000
        original.displayMode = .actualSize
        original.dynamicResolution = false
        original.launchFullScreen = true
        original.useAllMonitors = true
        original.retinaDisplay = true
        original.clipboard = true
        original.redirectedFolders = [RDPFolderExport(name: "Fixture", bookmark: Data([1, 2, 3]), readOnly: false)]
        original.wireGuardID = UUID()
        original.audioPlayback = false
        original.forwardingRules = [SSHForwardingRule(destinationPort: 80)]
        let saved = SavedConnection(draft: original)
        let copy = saved.duplicate()
        let duplicate = ConnectionDraft(copy)
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.name, "Fixture Copy")
        XCTAssertEqual(duplicate.host, original.host)
        XCTAssertEqual(duplicate.port, original.port)
        XCTAssertEqual(duplicate.kind, original.kind)
        XCTAssertEqual(duplicate.username, original.username)
        XCTAssertEqual(duplicate.domain, original.domain)
        XCTAssertEqual(duplicate.authentication, original.authentication)
        XCTAssertEqual(duplicate.folderID, original.folderID)
        XCTAssertEqual(duplicate.favorite, original.favorite)
        XCTAssertEqual(duplicate.notes, original.notes)
        XCTAssertEqual(duplicate.fontSize, original.fontSize)
        XCTAssertEqual(duplicate.terminalTheme, original.terminalTheme)
        XCTAssertEqual(duplicate.desktopWidth, original.desktopWidth)
        XCTAssertEqual(duplicate.desktopHeight, original.desktopHeight)
        XCTAssertEqual(duplicate.displayMode, original.displayMode)
        XCTAssertEqual(duplicate.dynamicResolution, original.dynamicResolution)
        XCTAssertEqual(duplicate.launchFullScreen, original.launchFullScreen)
        XCTAssertEqual(duplicate.useAllMonitors, original.useAllMonitors)
        XCTAssertEqual(duplicate.retinaDisplay, original.retinaDisplay)
        XCTAssertEqual(duplicate.clipboard, original.clipboard)
        XCTAssertEqual(duplicate.redirectedFolders, original.redirectedFolders)
        XCTAssertEqual(duplicate.wireGuardID, original.wireGuardID)
        XCTAssertEqual(duplicate.audioPlayback, original.audioPlayback)
        XCTAssertEqual(duplicate.forwardingRules, original.forwardingRules)
        XCTAssertNil(copy.lastConnected)
        saved.rdpDisplayMode = "future-mode"
        saved.rdpLaunchFullScreen = nil
        saved.rdpFolderExports = Data([255])
        saved.sshForwardingRules = Data([255])
        let rawCopy = saved.duplicate()
        XCTAssertEqual(rawCopy.rdpDisplayMode, saved.rdpDisplayMode)
        XCTAssertEqual(rawCopy.rdpLaunchFullScreen, saved.rdpLaunchFullScreen)
        XCTAssertEqual(rawCopy.rdpFolderExports, saved.rdpFolderExports)
        XCTAssertEqual(rawCopy.sshForwardingRules, saved.sshForwardingRules)
    }
    @MainActor func testOptionalMetadataRoundTripAndMalformedDataFailsClosed() throws {
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        var draft = ConnectionDraft()
        draft.host = "fixture.example"
        draft.username = "fixture"
        draft.forwardingRules = [
            SSHForwardingRule(destinationPort: 5432), SSHForwardingRule(kind: .socks, enabled: false),
        ]
        let saved = SavedConnection(draft: draft)
        container.mainContext.insert(saved)
        try container.mainContext.save()
        XCTAssertEqual(ConnectionDraft(saved).forwardingRules, draft.forwardingRules)
        draft.forwardingRules[0].destinationPort = 3306
        saved.update(from: draft)
        XCTAssertEqual(ConnectionDraft(saved).forwardingRules, draft.forwardingRules)
        saved.sshForwardingRules = nil
        XCTAssertTrue(ConnectionDraft(saved).forwardingRules.isEmpty)
        XCTAssertFalse(ConnectionDraft(saved).forwardingRulesUnavailable)
        saved.sshForwardingRules = Data("invalid".utf8)
        XCTAssertTrue(ConnectionDraft(saved).forwardingRulesUnavailable)
        XCTAssertNotNil(ConnectionDraft(saved).validationMessage)
    }
}
