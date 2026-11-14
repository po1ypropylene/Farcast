import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

@MainActor final class FolderLibraryImportTests: XCTestCase {
    private func container(_ url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        return try ModelContainer(
            for: schema,
            configurations: url.map { ModelConfiguration(schema: schema, url: $0) }
                ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }

    private func fixture(_ body: (URL, URL, UUID, ConnectionStorage) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Farcast-FolderTest-\(UUID())")
        try StorageFile.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent(".farcast-key")
        let storage = try ConnectionStorage.create(root.appendingPathComponent(".farcast-connections"), keyFile: key)
        let source = try container(storage.root.appendingPathComponent("default.store"))
        var draft = ConnectionDraft()
        draft.name = "Synthetic connection"
        draft.host = "fixture.example"
        source.mainContext.insert(SavedConnection(draft: draft))
        try source.mainContext.save()
        try storage.credentials.save(ConnectionCredential(password: "synthetic source"), for: draft.id)
        try body(root, key, draft.id, storage)
    }

    func testReadOnlyMovedKeyMergeAndRepeat() throws {
        try fixture { root, key, id, storage in
            let movedKey = root.appendingPathComponent("moved-key")
            try FileManager.default.moveItem(at: key, to: movedKey)
            let sourceBytes = try StorageFile.read(storage.root.appendingPathComponent("default.store"))
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: movedKey.path)
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let unlocked = try ConnectionStorage.openForImport(storage.root, keyFile: movedKey)
            let destination = try container()
            let credentials = LocalCredentialStore(root: root.appendingPathComponent("destination"))
            let result = try source.apply(
                to: destination, mode: .merge, unlocked: unlocked, includeCredentials: true,
                load: credentials.load, save: credentials.save, delete: credentials.delete)
            XCTAssertEqual(result.imported, 1)
            XCTAssertEqual(try credentials.load(id)?.password, "synthetic source")
            try credentials.save(ConnectionCredential(password: "local edit"), for: id)
            let repeated = try source.apply(
                to: destination, mode: .merge, unlocked: unlocked, includeCredentials: true,
                load: credentials.load, save: credentials.save, delete: credentials.delete)
            XCTAssertEqual(repeated.imported, 0)
            XCTAssertEqual(repeated.skipped, 1)
            XCTAssertEqual(try credentials.load(id)?.password, "local edit")
            XCTAssertEqual(try StorageFile.read(storage.root.appendingPathComponent("default.store")), sourceBytes)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: movedKey.path)[.posixPermissions] as? Int, 0o400)
            XCTAssertThrowsError(try FolderLibraryImport(root: storage.root, currentRoot: storage.root))
        }
    }

    func testPasswordAndUnencryptedSourcesUseDestinationProtection() throws {
        for protection in [CredentialProtection.password, .unencrypted] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Farcast-ImportProtection-\(UUID())")
            try StorageFile.directory(root)
            defer { try? FileManager.default.removeItem(at: root) }
            let storage = try ConnectionStorage.create(
                root.appendingPathComponent("source"), protection: protection,
                password: "synthetic unlock")
            let metadata = try container(storage.root.appendingPathComponent("default.store"))
            let profile = SavedConnection(draft: ConnectionDraft())
            metadata.mainContext.insert(profile)
            try metadata.mainContext.save()
            try storage.credentials.save(ConnectionCredential(password: "synthetic credential"), for: profile.id)
            if protection == .password {
                XCTAssertThrowsError(try ConnectionStorage.openForImport(storage.root, password: "wrong"))
            }
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let destinationStorage = try ConnectionStorage.create(
                root.appendingPathComponent("destination"),
                keyFile: root.appendingPathComponent("key"))
            let credentials = destinationStorage.credentials
            let destination = try container()
            _ = try source.apply(
                to: destination, mode: .merge,
                unlocked: ConnectionStorage.openForImport(storage.root, password: "synthetic unlock"),
                includeCredentials: true, load: credentials.load, save: credentials.save, delete: credentials.delete)
            XCTAssertEqual(try credentials.load(profile.id)?.password, "synthetic credential")
            let written = try StorageFile.read(credentials.root.appendingPathComponent(profile.id.uuidString + ".json"))
            XCTAssertNil(written.range(of: Data("synthetic credential".utf8)))
        }
    }

    func testReplaceClearsAssociatedCredentialsAndRetainsSource() throws {
        try fixture { root, key, id, storage in
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let destination = try container()
            var old = ConnectionDraft()
            old.name = "Existing"
            old.host = "old.example"
            destination.mainContext.insert(SavedConnection(draft: old))
            try destination.mainContext.save()
            let credentials = LocalCredentialStore(root: root.appendingPathComponent("destination"))
            try credentials.save(ConnectionCredential(password: "old"), for: old.id)
            _ = try source.apply(
                to: destination, mode: .replace,
                unlocked: ConnectionStorage.openForImport(storage.root, keyFile: key), includeCredentials: true,
                load: credentials.load, save: credentials.save, delete: credentials.delete)
            XCTAssertNil(try credentials.load(old.id))
            XCTAssertEqual(try credentials.load(id)?.password, "synthetic source")
            XCTAssertEqual(try ModelContext(destination).fetch(FetchDescriptor<SavedConnection>()).map(\.id), [id])
            XCTAssertEqual(try storage.credentials.load(id)?.password, "synthetic source")
            // Replacing the same stable ID must not leave duplicate or deleted metadata.
            _ = try source.apply(
                to: destination, mode: .replace, unlocked: nil, includeCredentials: false,
                load: credentials.load, save: credentials.save, delete: credentials.delete)
            XCTAssertNil(try credentials.load(id))
            XCTAssertEqual(try ModelContext(destination).fetch(FetchDescriptor<SavedConnection>()).map(\.id), [id])
        }
    }

    func testMetadataOnlyMergeCannotAttachOrphanedCredentials() throws {
        try fixture { root, _, id, storage in
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let destination = try container()
            let credentials = LocalCredentialStore(root: root.appendingPathComponent("destination"))
            try credentials.save(ConnectionCredential(password: "orphan"), for: id)
            XCTAssertThrowsError(
                try source.apply(
                    to: destination, mode: .merge, unlocked: nil, includeCredentials: false,
                    load: credentials.load, save: credentials.save, delete: credentials.delete))
            XCTAssertEqual(try ModelContext(destination).fetchCount(FetchDescriptor<SavedConnection>()), 0)
            XCTAssertEqual(try credentials.load(id)?.password, "orphan")
        }
    }

    func testWriteFailureRollsBackMetadataAndCredentials() throws {
        try fixture { root, key, id, storage in
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let destination = try container()
            var draft = ConnectionDraft()
            draft.id = id
            draft.name = "Original"
            draft.host = "old.example"
            destination.mainContext.insert(SavedConnection(draft: draft))
            try destination.mainContext.save()
            let credentials = LocalCredentialStore(root: root.appendingPathComponent("destination"))
            try credentials.save(ConnectionCredential(password: "original"), for: id)
            var fail = true
            XCTAssertThrowsError(
                try source.apply(
                    to: destination, mode: .replace,
                    unlocked: ConnectionStorage.openForImport(storage.root, keyFile: key), includeCredentials: true,
                    load: credentials.load,
                    save: { value, id in
                        try credentials.save(value, for: id)
                        if fail {
                            fail = false
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }, delete: credentials.delete))
            XCTAssertEqual(try credentials.load(id)?.password, "original")
            XCTAssertEqual(
                try ModelContext(destination).fetch(FetchDescriptor<SavedConnection>()).first?.name, "Original")
        }
    }

    func testWrongKeyAndCorruptCredentialCannotClearDestination() throws {
        try fixture { root, key, id, storage in
            let wrong = root.appendingPathComponent("wrong")
            try StorageFile.write(Data(repeating: 7, count: 16), to: wrong)
            XCTAssertThrowsError(try ConnectionStorage.openForImport(storage.root, keyFile: wrong))
            try StorageFile.write(
                Data("bad".utf8), to: storage.credentials.root.appendingPathComponent(id.uuidString + ".json"))
            let source = try FolderLibraryImport(root: storage.root, currentRoot: nil)
            let destination = try container()
            let original = SavedConnection(draft: ConnectionDraft())
            destination.mainContext.insert(original)
            try destination.mainContext.save()
            XCTAssertThrowsError(
                try source.apply(
                    to: destination, mode: .replace,
                    unlocked: ConnectionStorage.openForImport(storage.root, keyFile: key), includeCredentials: true,
                    load: { _ in
                        XCTFail("Must decode before reading destination secrets")
                        return nil
                    },
                    save: { _, _ in XCTFail("Must not write") }, delete: { _ in XCTFail("Must not clear") }))
            XCTAssertEqual(
                try ModelContext(destination).fetch(FetchDescriptor<SavedConnection>()).first?.id, original.id)
        }
    }
}
