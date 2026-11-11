import SwiftData
import XCTest

@testable import FarcastCore

final class CoreTests: XCTestCase {
    func testResizeOptInOverridesButPreservesStoredDisplayMode() {
        var draft = ConnectionDraft()
        XCTAssertFalse(draft.dynamicResolution)
        draft.kind = .rdp
        for mode in RDPDisplayMode.allCases {
            draft.displayMode = mode
            draft.dynamicResolution = true
            let restored = ConnectionDraft(SavedConnection(draft: draft))
            XCTAssertEqual(restored.displayMode, mode)
            XCTAssertEqual(restored.effectiveDisplayMode, .fit)
            draft.dynamicResolution = false
            XCTAssertEqual(draft.effectiveDisplayMode, mode)
        }
        draft.kind = .vnc
        draft.displayMode = .actualSize
        draft.dynamicResolution = true
        XCTAssertEqual(draft.effectiveDisplayMode, .actualSize)
    }
    func testValidationAndIPv6Normalization() {
        var profile = ConnectionDraft()
        profile.host = " [2001:db8::1] "
        profile.username = " root "
        profile.normalize()
        XCTAssertNil(profile.validationMessage)
        XCTAssertEqual(profile.host, "2001:db8::1")
        XCTAssertEqual(profile.name, "2001:db8::1")
        XCTAssertEqual(profile.username, "root")
        profile.port = 0
        XCTAssertNotNil(profile.validationMessage)
        profile.port = 65536
        XCTAssertNotNil(profile.validationMessage)
        profile.port = 22
        profile.host = "ssh://example.com"
        XCTAssertNotNil(profile.validationMessage)
        profile.host = "server example.com"
        XCTAssertNotNil(profile.validationMessage)
        for address in ["server.example:3389", "192.0.2.1:3389", "[2001:db8::1]:3389"] {
            profile.host = address
            XCTAssertNotNil(profile.validationMessage)
        }
        profile.host = "2001:db8::1"
        XCTAssertNil(profile.validationMessage)
    }
    func testRedirectedFolderValidation() {
        var draft = ConnectionDraft()
        draft.host = "synthetic.example"
        draft.username = "fixture"
        draft.kind = .rdp
        draft.redirectedFolders = [RDPFolderExport(name: "Documents", bookmark: Data([1]))]
        XCTAssertNil(draft.validationMessage)
        draft.redirectedFolders.append(RDPFolderExport(name: "documents", bookmark: Data([2])))
        XCTAssertNotNil(draft.validationMessage)
        draft.redirectedFolders = [RDPFolderExport(name: "../escape", bookmark: Data([1]))]
        XCTAssertNotNil(draft.validationMessage)
        draft.redirectedFolders = [RDPFolderExport(name: "Files", bookmark: Data())]
        XCTAssertNotNil(draft.validationMessage)
    }
    func testConnectionFieldsRejectCStringTruncationAndURLSyntax() {
        var draft = ConnectionDraft()
        draft.username = "fixture"
        for host in ["server\0other", "server\u{7f}", "user@server", "server?query", "server#fragment", "server\\path"]
        {
            draft.host = host
            XCTAssertNotNil(draft.validationMessage)
        }
        draft.host = "fixture.invalid"
        draft.username = "fixture\0other"
        XCTAssertNotNil(draft.validationMessage)
        draft.username = "fixture"
        draft.kind = .rdp
        draft.domain = "domain\0other"
        XCTAssertNotNil(draft.validationMessage)
        XCTAssertFalse(WireGuardConfiguration.validList("192.0.2.1\0other/24", prefix: true))
        var rule = SSHForwardingRule()
        rule.kind = .remote
        rule.bindAddress = "127.0.0.1\0other"
        rule.destinationPort = 22
        XCTAssertNotNil(rule.validationMessage)
    }
    func testEndpointTrustIsSeparatedByProtocolAndPort() {
        var ssh = ConnectionDraft()
        ssh.host = "SERVER.EXAMPLE"
        ssh.username = "root"
        var rdp = ssh
        rdp.kind = .rdp
        rdp.port = 3389
        XCTAssertNotEqual(ssh.endpointKey, rdp.endpointKey)
        var alternate = ssh
        alternate.port = 2222
        XCTAssertNotEqual(ssh.endpointKey, alternate.endpointKey)
        alternate.port = 22
        alternate.host = "server.example"
        XCTAssertEqual(ssh.endpointKey, alternate.endpointKey)
    }
    func testSSHConfigImportUsesMetadataAndFirstMatchingDefaults() throws {
        let imported = try SSHConfigImport(
            text: """
                User default-user
                Host lab alternate
                    HostName "lab.example" # comment
                    Port=2222
                    IdentityFile ~/.ssh/private-key
                Host blocked
                    HostName blocked.example
                    ProxyCommand never-execute-this
                Host jump
                    ProxyJump lab
                Host * !blocked
                    Port 2200
                Match exec never-execute-this
                    HostName ignored.example
                """)
        XCTAssertEqual(imported.entries.map(\.alias), ["lab", "alternate"])
        XCTAssertEqual(imported.entries.map(\.host), ["lab.example", "lab.example"])
        XCTAssertTrue(imported.entries.allSatisfy { $0.username == "default-user" && $0.port == 2222 })
        let defaults = try SSHConfigImport(text: "Host *\n Port 2200\nHost machine\n HostName %h.example\n Port 2222")
        XCTAssertEqual(defaults.entries.first?.host, "machine.example")
        XCTAssertEqual(defaults.entries.first?.port, 2200)
    }
    func testSSHConfigImportRejectsInvalidAndSkipsUnsupportedHosts() throws {
        XCTAssertThrowsError(try SSHConfigImport(text: "Host \"unterminated"))
        XCTAssertThrowsError(try SSHConfigImport(text: String(repeating: "a", count: 1_048_577)))
        let imported = try SSHConfigImport(
            text:
                "Host *.example !excluded\nHost invalid\n Port 65536\nHost unsupported\n HostName %n.example\nInclude /not/read"
        )
        XCTAssertTrue(imported.entries.isEmpty)
    }
    func testSSHConfigPatternsHaveBoundedBacktrackingAndLiteralBrackets() throws {
        let alias = String(repeating: "a", count: 60)
        let pattern = String(repeating: "*a", count: 30) + "b"
        let imported = try SSHConfigImport(
            text:
                "Host \(pattern)\n Port 2200\nHost a?* !excluded\n User fixture\nHost \(alias)\nHost [literal]\n Port 2222"
        )
        XCTAssertEqual(imported.entries.first?.port, 22)
        XCTAssertEqual(imported.entries.first?.username, "fixture")
        XCTAssertEqual(imported.entries.last?.host, "[literal]")
        XCTAssertEqual(imported.entries.last?.port, 2222)
        XCTAssertThrowsError(
            try SSHConfigImport(
                text: (0...2_000).map { "Host machine\($0)\n ProxyJump skipped" }.joined(separator: "\n")))
    }
    @MainActor func testSidebarMetadataSurvivesRenameAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([SavedConnection.self, ConnectionFolder.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("library.store"))
        let container = try ModelContainer(for: schema, configurations: [config])
        let parent = ConnectionFolder(name: "Parent")
        let child = ConnectionFolder(name: "Child")
        child.parentID = parent.id
        child.isCollapsed = true
        var draft = ConnectionDraft()
        draft.name = "Server"
        draft.host = "server.example"
        draft.folderID = child.id
        draft.favorite = true
        let profile = SavedConnection(draft: draft)
        profile.favoriteOrder = 4
        container.mainContext.insert(parent)
        container.mainContext.insert(child)
        container.mainContext.insert(profile)
        try container.mainContext.save()
        child.name = "Renamed"
        try container.mainContext.save()
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let folders = try reopened.mainContext.fetch(FetchDescriptor<ConnectionFolder>())
        let restored = try XCTUnwrap(folders.first { $0.id == child.id })
        XCTAssertEqual(restored.name, "Renamed")
        XCTAssertEqual(restored.parentID, parent.id)
        XCTAssertEqual(restored.isCollapsed, true)
        let profiles = try reopened.mainContext.fetch(FetchDescriptor<SavedConnection>())
        XCTAssertEqual(profiles.first?.folderID, child.id)
        XCTAssertEqual(profiles.first?.favoriteOrder, 4)
        XCTAssertEqual(profiles.first?.favorite, true)
    }
    @MainActor func testProfileAndFolderPersistenceDoesNotStoreCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([SavedConnection.self, ConnectionFolder.self])
        let config = ModelConfiguration(schema: schema, url: root.appendingPathComponent("library.store"))
        let first = try ModelContainer(for: schema, configurations: [config])
        var draft = ConnectionDraft()
        draft.name = "Production"
        draft.host = "server.example"
        draft.username = "operator"
        let folder = ConnectionFolder(name: "Servers")
        draft.folderID = folder.id
        draft.kind = .rdp
        draft.port = 3389
        draft.redirectedFolders = [RDPFolderExport(name: "Mac files", bookmark: Data([1, 2, 3]), readOnly: false)]
        draft.clipboard = true
        draft.audioPlayback = false
        draft.dynamicResolution = false
        draft.displayMode = .matchWindow
        first.mainContext.insert(folder)
        first.mainContext.insert(SavedConnection(draft: draft))
        try first.mainContext.save()
        let reopened = try ModelContainer(for: schema, configurations: [config])
        let profiles = try reopened.mainContext.fetch(FetchDescriptor<SavedConnection>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].folderID, folder.id)
        let restored = ConnectionDraft(profiles[0])
        XCTAssertEqual(restored.kind, .rdp)
        XCTAssertEqual(restored.redirectedFolders, draft.redirectedFolders)
        profiles[0].rdpFolderExports = Data([0, 255])
        let damaged = ConnectionDraft(profiles[0])
        XCTAssertTrue(damaged.redirectedFoldersUnavailable)
        XCTAssertNotNil(damaged.validationMessage)
        profiles[0].rdpFolderExports = try JSONEncoder().encode(draft.redirectedFolders)
        XCTAssertTrue(restored.clipboard)
        XCTAssertFalse(restored.audioPlayback)
        XCTAssertFalse(restored.dynamicResolution)
        XCTAssertEqual(restored.displayMode, .matchWindow)
        profiles[0].rdpDisplayMode = nil
        XCTAssertEqual(ConnectionDraft(profiles[0]).displayMode, .fit)
        profiles[0].rdpDisplayMode = "unknown"
        XCTAssertEqual(ConnectionDraft(profiles[0]).displayMode, .fit)
        let fieldNames = schema.entities.first { $0.name == "SavedConnection" }!.properties.map(\.name)
        XCTAssertFalse(fieldNames.contains("password"))
        XCTAssertFalse(fieldNames.contains("privateKey"))
    }
    func testCredentialEncodingPreservesKeyBytesAndPassphrase() throws {
        let secret = ConnectionCredential(
            password: "fixture-passphrase", privateKey: Data([0, 1, 255]), keyName: "fixture.pem")
        let restored = try JSONDecoder().decode(ConnectionCredential.self, from: JSONEncoder().encode(secret))
        XCTAssertEqual(restored.password, secret.password)
        XCTAssertEqual(restored.privateKey, secret.privateKey)
    }
    @MainActor func testTrustStoreRequiresMatchingFingerprintAndCanForget() {
        let name = "Farcast.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = TrustStore(defaults: defaults)
        XCTAssertNil(store.fingerprint(for: "SSH|fixture|22"))
        store.remember("SHA256:first", for: "SSH|fixture|22")
        XCTAssertEqual(store.fingerprint(for: "SSH|fixture|22"), "SHA256:first")
        XCTAssertNotEqual(store.fingerprint(for: "SSH|fixture|22"), "SHA256:changed")
        XCTAssertNil(store.fingerprint(for: "RDP|fixture|22"))
        store.forget("SSH|fixture|22")
        XCTAssertNil(store.fingerprint(for: "SSH|fixture|22"))
    }
    func testPromptCancellationAndSingleResolution() {
        let waiter = PromptWaiter()
        waiter.resolve(nil)
        waiter.resolve("late result")
        XCTAssertNil(waiter.wait())
        let accepted = PromptWaiter()
        accepted.resolve("approved")
        accepted.resolve(nil)
        XCTAssertEqual(accepted.wait(), "approved")
    }
}
