import Foundation
import SwiftData
import XCTest

@testable import FarcastCore

@MainActor final class ExistingLibraryImportTests: XCTestCase {
    private func container(at url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([SavedConnection.self, ConnectionFolder.self, SavedWireGuard.self])
        let configuration =
            url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func withLibrary(_ check: (URL, UUID) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Farcast-ImportTest-\(UUID())")
        let support = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        try seed(at: support.appendingPathComponent("default.store"), id: id)
        try check(root, id)
    }

    private func seed(at url: URL, id: UUID) throws {
        let source = try container(at: url)
        var draft = ConnectionDraft()
        draft.id = id
        draft.name = "Synthetic import"
        draft.host = "fixture.example"
        draft.username = "fixture"
        source.mainContext.insert(SavedConnection(draft: draft))
        try source.mainContext.save()
    }

    func testImportPreservesIDsAndRejectsNonemptyDestination() throws {
        try withLibrary { root, id in
            let destination = try container()
            let suite = "com.peterpo.farcast.Tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            XCTAssertEqual(
                try ExistingLibraryImporter.importLibrary(
                    from: root, into: destination, includeLocalCredentials: false, defaults: defaults), 1)
            let context = ModelContext(destination)
            XCTAssertEqual(try context.fetch(FetchDescriptor<SavedConnection>()).first?.id, id)
            XCTAssertThrowsError(
                try ExistingLibraryImporter.importLibrary(
                    from: root, into: destination, includeLocalCredentials: false, defaults: defaults))
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedConnection>()), 1)
        }
    }

    func testLocalCredentialsRequireOptInAndMalformedInputLeavesDestinationEmpty() throws {
        try withLibrary { root, id in
            let oldRoot = root.appendingPathComponent(
                "Application Support/\(PreviousLibraryIdentity.credentialDirectory)")
            let old = LocalCredentialStore(root: oldRoot)
            try old.save(ConnectionCredential(password: "synthetic", privateKey: Data([1, 2])), for: id)
            let copiedRoot = root.appendingPathComponent("NewCredentials")
            let copied = LocalCredentialStore(root: copiedRoot)
            let suite = "com.peterpo.farcast.Tests.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let without = try container()
            _ = try ExistingLibraryImporter.importLibrary(
                from: root, into: without, includeLocalCredentials: false, credentials: copied, defaults: defaults)
            XCTAssertNil(try copied.load(id))
            let with = try container()
            _ = try ExistingLibraryImporter.importLibrary(
                from: root, into: with, includeLocalCredentials: true, credentials: copied, defaults: defaults)
            XCTAssertEqual(try copied.load(id)?.password, "synthetic")
            XCTAssertEqual(try copied.load(id)?.privateKey, Data([1, 2]))
            XCTAssertEqual(try old.load(id)?.password, "synthetic")
            try Data("invalid synthetic credential".utf8).write(
                to: oldRoot.appendingPathComponent(id.uuidString + ".json"))
            let rejected = try container()
            XCTAssertThrowsError(
                try ExistingLibraryImporter.importLibrary(
                    from: root, into: rejected, includeLocalCredentials: true, credentials: copied, defaults: defaults))
            XCTAssertEqual(try ModelContext(rejected).fetchCount(FetchDescriptor<SavedConnection>()), 0)
        }
    }

    func testSymlinkInputIsRejectedWithoutChangingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Farcast-LinkTest-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Application Support"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("synthetic target".utf8)
        let target = root.appendingPathComponent("original.store")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Application Support/default.store"), withDestinationURL: target)
        XCTAssertThrowsError(
            try ExistingLibraryImporter.importLibrary(
                from: root, into: container(), includeLocalCredentials: false))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testImportPreservesAbsentOptionalMacMode() throws {
        try withLibrary { root, _ in
            let source = try container(at: root.appendingPathComponent("Application Support/default.store"))
            let profile = try XCTUnwrap(source.mainContext.fetch(FetchDescriptor<SavedConnection>()).first)
            profile.protocolName = RemoteProtocol.vnc.rawValue
            profile.vncRemoteIsMac = nil
            try source.mainContext.save()
            let destination = try container()
            _ = try ExistingLibraryImporter.importLibrary(
                from: root, into: destination, includeLocalCredentials: false)
            let copy = try XCTUnwrap(ModelContext(destination).fetch(FetchDescriptor<SavedConnection>()).first)
            XCTAssertNil(copy.vncRemoteIsMac)
            XCTAssertEqual(copy.protocolName, RemoteProtocol.vnc.rawValue)
        }
    }
}
