import CryptoKit
import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

final class ConnectionStorageTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try StorageFile.directory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAES128KeyFileRoundTripTamperingAndRecordBinding() throws {
        let root = try temporary()
        let key = root.appendingPathComponent("key")
        let library = root.appendingPathComponent("library")
        let storage = try ConnectionStorage.create(library, keyFile: key)
        XCTAssertEqual(try StorageFile.read(key).count, 16)
        let id = UUID()
        let secret = ConnectionCredential(password: "synthetic-secret", privateKey: Data([0, 255]))
        try storage.credentials.save(secret, for: id)
        let file = storage.credentials.root.appendingPathComponent(id.uuidString + ".json")
        let ciphertext = try StorageFile.read(file)
        XCTAssertNil(String(data: ciphertext, encoding: .utf8)?.range(of: secret.password))
        XCTAssertEqual(try ConnectionStorage.open(library).credentials.load(id)?.privateKey, secret.privateKey)
        let swappedID = UUID()
        try StorageFile.write(
            ciphertext, to: storage.credentials.root.appendingPathComponent(swappedID.uuidString + ".json"))
        XCTAssertThrowsError(try storage.credentials.load(swappedID))
        var corrupt = ciphertext
        corrupt[corrupt.count - 1] ^= 1
        try StorageFile.write(corrupt, to: file)
        XCTAssertThrowsError(try storage.credentials.load(id))
        try FileManager.default.removeItem(at: key)
        XCTAssertThrowsError(try ConnectionStorage.open(library))
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path), "Opening must never regenerate a missing key")
    }

    func testPasswordWrongPasswordAndProtectionChanges() throws {
        let root = try temporary()
        let library = root.appendingPathComponent("library")
        let storage = try ConnectionStorage.create(library, protection: .password, password: "fixture-password")
        let id = UUID()
        try storage.credentials.save(ConnectionCredential(password: "fixture"), for: id)
        XCTAssertThrowsError(try ConnectionStorage.open(library, password: "wrong"))
        XCTAssertEqual(
            try ConnectionStorage.open(library, password: "fixture-password").credentials.load(id)?.password, "fixture")
        let oldDirectory = storage.credentials.root
        let plain = try storage.changingProtection(
            .unencrypted, keyFile: root.appendingPathComponent("unused"), password: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertEqual(try plain.credentials.load(id)?.password, "fixture")
        let file = plain.credentials.root.appendingPathComponent(id.uuidString + ".json")
        XCTAssertNotNil(String(data: try StorageFile.read(file), encoding: .utf8)?.range(of: "fixture"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        let encrypted = try plain.changingProtection(
            .keyFile, keyFile: root.appendingPathComponent("key"), password: "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.credentials.root.path))
        XCTAssertEqual(try encrypted.credentials.load(id)?.password, "fixture")
        let manifest = try StorageFile.read(library.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(
            try encrypted.changingProtection(.password, keyFile: root.appendingPathComponent("key"), password: ""))
        XCTAssertEqual(try StorageFile.read(library.appendingPathComponent("storage.json")), manifest)
        XCTAssertEqual(try ConnectionStorage.open(library).credentials.load(id)?.password, "fixture")
    }

    func testFailedReencryptionPreservesManifestAndOriginalRecords() throws {
        let root = try temporary()
        let library = root.appendingPathComponent("library")
        let storage = try ConnectionStorage.create(library, keyFile: root.appendingPathComponent("key"))
        let id = UUID()
        try storage.credentials.save(ConnectionCredential(password: "fixture"), for: id)
        let badID = UUID()
        try StorageFile.write(
            Data([1, 2, 3]), to: storage.credentials.root.appendingPathComponent(badID.uuidString + ".json"))
        let manifest = try StorageFile.read(library.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(
            try storage.changingProtection(.unencrypted, keyFile: root.appendingPathComponent("key"), password: ""))
        XCTAssertEqual(try StorageFile.read(library.appendingPathComponent("storage.json")), manifest)
        XCTAssertEqual(try storage.credentials.load(id)?.password, "fixture")
    }

    func testRejectsSymlinkKeysAndManifestPathTraversal() throws {
        let root = try temporary()
        let key = root.appendingPathComponent("key")
        try StorageFile.write(Data(repeating: 1, count: 16), to: key)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: key)
        XCTAssertThrowsError(try ConnectionStorage.create(root.appendingPathComponent("library"), keyFile: link))
        let storage = try ConnectionStorage.create(root.appendingPathComponent("plain"), protection: .unencrypted)
        var manifest = storage.manifest
        manifest.credentialsDirectory = "../outside"
        try StorageFile.write(
            try JSONEncoder().encode(manifest), to: storage.root.appendingPathComponent("storage.json"))
        XCTAssertThrowsError(try ConnectionStorage.open(storage.root))
    }

    @MainActor func testMigrationRetainsIdentityRawMetadataVPNAndCredentialsWithoutChangingSource() throws {
        let root = try temporary()
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let source = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let target = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var draft = ConnectionDraft()
        draft.host = "fixture.example"
        let profile = SavedConnection(draft: draft)
        profile.protocolName = "Future protocol"
        profile.authentication = "Future auth"
        profile.rdpDisplayMode = "Future display"
        profile.rdpFolderExports = Data([1, 3, 5])
        profile.vncRemoteIsMac = nil
        profile.favoriteOrder = 3
        profile.created = Date(timeIntervalSince1970: 12)
        let folder = ConnectionFolder(name: "Synthetic")
        folder.isCollapsed = true
        profile.folderID = folder.id
        let vpn = try SavedWireGuard(name: "Synthetic VPN", configuration: WireGuardConfiguration())
        profile.wireGuardID = vpn.id
        source.mainContext.insert(profile)
        source.mainContext.insert(folder)
        source.mainContext.insert(vpn)
        try source.mainContext.save()
        let storage = try ConnectionStorage.create(
            root.appendingPathComponent("library"), keyFile: root.appendingPathComponent("key"))
        let previousAutosave = target.mainContext.autosaveEnabled
        try ConnectionLibraryMigration.copy(
            from: source.mainContext, to: target.mainContext,
            load: { _ in ConnectionCredential(password: "fixture", wireGuardPrivateKey: "synthetic") },
            targetLoad: storage.credentials.load, save: { try storage.credentials.save($0, for: $1) },
            delete: storage.credentials.delete)
        XCTAssertEqual(target.mainContext.autosaveEnabled, previousAutosave)
        let copy = try XCTUnwrap(target.mainContext.fetch(FetchDescriptor<SavedConnection>()).first)
        XCTAssertEqual(copy.id, profile.id)
        XCTAssertEqual(copy.protocolName, profile.protocolName)
        XCTAssertEqual(copy.authentication, profile.authentication)
        XCTAssertEqual(copy.rdpDisplayMode, profile.rdpDisplayMode)
        XCTAssertEqual(copy.rdpFolderExports, profile.rdpFolderExports)
        XCTAssertEqual(copy.favoriteOrder, profile.favoriteOrder)
        XCTAssertEqual(copy.created, profile.created)
        XCTAssertEqual(copy.wireGuardID, vpn.id)
        XCTAssertEqual(try target.mainContext.fetch(FetchDescriptor<ConnectionFolder>()).first?.isCollapsed, true)
        XCTAssertEqual(try source.mainContext.fetchCount(FetchDescriptor<SavedConnection>()), 1)
        XCTAssertEqual(try storage.credentials.load(profile.id)?.password, "fixture")
        XCTAssertEqual(try storage.credentials.load(vpn.id)?.wireGuardPrivateKey, "synthetic")
        XCTAssertThrowsError(
            try ConnectionLibraryMigration.copy(
                from: source.mainContext, to: target.mainContext, load: { _ in nil }, targetLoad: { _ in nil },
                save: { _, _ in XCTFail("Must not overwrite") }, delete: { _ in }))
    }

    @MainActor func testMigrationRollsBackMetadataAndCredentialsAfterWriteFailure() throws {
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let source = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let target = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        source.mainContext.insert(SavedConnection(draft: ConnectionDraft()))
        source.mainContext.insert(SavedConnection(draft: ConnectionDraft()))
        var written = Set<UUID>()
        var attempts = 0
        XCTAssertThrowsError(
            try ConnectionLibraryMigration.copy(
                from: source.mainContext, to: target.mainContext,
                load: { _ in ConnectionCredential(password: "fixture") }, targetLoad: { _ in nil },
                save: { _, id in
                    attempts += 1
                    if attempts == 2 { throw ConnectionStorageError.invalid }
                    written.insert(id)
                }, delete: { written.remove($0) }))
        XCTAssertTrue(written.isEmpty)
        XCTAssertEqual(try target.mainContext.fetchCount(FetchDescriptor<SavedConnection>()), 0)
        XCTAssertEqual(try source.mainContext.fetchCount(FetchDescriptor<SavedConnection>()), 2)
    }
}
