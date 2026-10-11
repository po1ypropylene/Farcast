import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

enum SSHWorkspaceMode: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case files = "Files"
    case split = "Split"
    var id: String { rawValue }
}

struct TransferFile: Identifiable, Equatable {
    let name: String
    let directory: Bool
    let regular: Bool
    let size: UInt64
    var id: String { name }
    var transferable: Bool { directory || regular }
    var sizeLabel: String {
        directory ? "Folder" : ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }
}

private final class FileWorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

private struct FileJob: Sendable {
    let operation: String
    let source: String
    let destination: String
    var move = false
    var local = false
    var preview: URL?
    var cutSource: String?
}

struct FileConflict: Identifiable {
    let id: String
    let name: String
}

private struct FileBuffer {
    let local: Bool
    var sources: [String]
    let cut: Bool
}

/// One controller per SSH session. Local folders and buffered sources retain their security scopes.
@MainActor final class SFTPController: ObservableObject {
    @Published var remotePath = "."
    @Published var remoteFiles: [TransferFile] = []
    @Published var localURL: URL?
    @Published var localFiles: [TransferFile] = []
    @Published var busy = false
    @Published private(set) var needsLocalAccess = true
    @Published private(set) var cancelling = false
    @Published var message = "Choose Files or Split to browse this server."
    @Published var progress: Double?
    @Published private(set) var transferredBytes: UInt64 = 0
    private var transferStarted: TimeInterval?
    private let clock: () -> TimeInterval
    var transferSpeed: Double? {
        guard let transferStarted, !cancelling else { return nil }
        return Double(transferredBytes) / max(0.001, clock() - transferStarted)
    }
    private func resetTransferSpeed() {
        transferredBytes = 0
        transferStarted = nil
    }
    @Published var error: String?
    @Published private(set) var conflict: FileConflict?
    private var overwriteAll = false
    @Published private(set) var bufferedCount = 0
    private weak var client: FCSSHClient?
    private var requestID: String?
    private var requestIsListing = false
    private var requestPath = "."
    private var requested = false
    private var scope: URL?
    private var bufferScope: URL?
    private var buffer: FileBuffer?
    private var jobs: [FileJob] = []
    private var activeJob: FileJob?
    private var batchCount = 0
    private var completed = 0
    private var localWork = FileWorkCancellation()
    private let homeURL: URL
    private var askedForHome = false
    private var dragToken: String?
    private var draggedSources: [String] = []
    private var draggedLocal = false
    private var dropScopes: [URL] = []
    private var dropProviders: [NSItemProvider] = []
    private var dropAttempt = UUID()
    static let dragType = UTType.utf8PlainText.identifier

    init(
        homeURL: URL? = nil, requiresAccess: Bool = true,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.clock = clock
        let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        self.homeURL = homeURL ?? URL(fileURLWithPath: realHome, isDirectory: true)
        localURL = self.homeURL
        if !requiresAccess {
            needsLocalAccess = false
            refreshLocal()
        } else if let bookmark = UserDefaults.standard.data(forKey: "sftpHomeAccess") {
            var stale = false
            if let restored = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale),
                restored.standardizedFileURL == self.homeURL.standardizedFileURL,
                restored.startAccessingSecurityScopedResource()
            {
                scope = restored
                localURL = restored
                needsLocalAccess = false
                if stale { saveHomeAccess(restored) }
                refreshLocal()
            }
        }
    }
    private func saveHomeAccess(_ url: URL) {
        guard url.standardizedFileURL == homeURL.standardizedFileURL,
            let data = try? url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        UserDefaults.standard.set(data, forKey: "sftpHomeAccess")
    }
    func prepareLocalAccess() {
        guard needsLocalAccess, !askedForHome else { return }
        askedForHome = true
        chooseLocalFolder()
    }
    func cancel() {
        guard busy, !cancelling else { return }
        cancelling = true
        conflict = nil
        jobs = []
        message = "Cancelling…"
        if activeJob == nil && !dropProviders.isEmpty {
            dropAttempt = UUID()
            releaseDropAccess()
            busy = false
            cancelling = false
            message = "Cancelled"
            return
        }
        if activeJob?.local == true { localWork.cancel() } else { client?.cancelFiles() }
    }
    private func releaseDropAccess() {
        for url in dropScopes { url.stopAccessingSecurityScopedResource() }
        dropScopes = []
        dropProviders = []
    }

    func attach(_ client: FCSSHClient) {
        self.client = client
        conflict = nil
        overwriteAll = false
        client.onFileConflict = { [weak self, weak client] token, name in
            DispatchQueue.main.async {
                guard let self, let client, self.client === client, self.busy, !self.cancelling else {
                    client?.resolveFileConflict(token, overwrite: false)
                    return
                }
                if self.overwriteAll {
                    client.resolveFileConflict(token, overwrite: true)
                } else {
                    self.conflict = FileConflict(id: token, name: name)
                }
            }
        }
        requested = false
        requestID = nil
        busy = false
        progress = nil
        resetTransferSpeed()
        error = nil
        remoteFiles = []
        remotePath = "."
        message = "Choose Files or Split to browse this server."
    }
    func resolveConflict(overwrite: Bool, all: Bool = false) {
        guard let conflict else { return }
        self.conflict = nil
        if all && overwrite { overwriteAll = true }
        client?.resolveFileConflict(conflict.id, overwrite: overwrite)
        if !overwrite { cancel() }
    }
    func showFiles() {
        guard !requested, !busy else { return }
        refreshRemote()
    }
    func refreshRemote(path: String? = nil) {
        guard !busy, let client else { return }
        requested = true
        requestIsListing = true
        requestPath = path ?? remotePath
        let id = begin("Reading server folder…")
        client.listDirectory(requestPath, requestID: id)
    }
    private func begin(_ text: String) -> String {
        let id = UUID().uuidString
        requestID = id
        busy = true
        progress = nil
        resetTransferSpeed()
        error = nil
        message = text
        return id
    }
    func receive(id: String, result: [AnyHashable: Any], error: String?) {
        guard requestID == id else { return }
        requestID = nil
        progress = nil
        resetTransferSpeed()
        if cancelling {
            cancelling = false
            busy = false
            activeJob = nil
            jobs = []
            self.error = nil
            message = "Cancelled"
            releaseDropAccess()
            refreshLocal()
            return
        }
        if let error {
            busy = false
            self.error = error
            jobs = []
            activeJob = nil
            releaseDropAccess()
            message = "Stopped after \(completed) completed items. Refresh to inspect partial destinations."
            refreshLocal()
            return
        }
        if requestIsListing {
            busy = false
            remotePath = result["path"] as? String ?? requestPath
            remoteFiles = sorted(
                (result["entries"] as? [[String: Any]] ?? []).compactMap { entry in
                    guard let name = entry["name"] as? String else { return nil }
                    return TransferFile(
                        name: name, directory: entry["directory"] as? Bool ?? false,
                        regular: entry["regular"] as? Bool ?? false,
                        size: (entry["size"] as? NSNumber)?.uint64Value ?? 0)
                })
            message = "\(remoteFiles.count) server items"
        } else {
            if let preview = activeJob?.preview, !NSWorkspace.shared.open(preview) {
                self.error = "The file was downloaded, but no application could open it."
                busy = false
                jobs = []
                activeJob = nil
                return
            }
            if let source = activeJob?.cutSource {
                buffer?.sources.removeAll { $0 == source }
                bufferedCount = buffer?.sources.count ?? 0
                if bufferedCount == 0 { clearBuffer() }
            }
            completed += 1
            activeJob = nil
            runNext()
        }
    }
    func receiveProgress(id: String, bytes: UInt64, total: UInt64) {
        guard requestID == id, !cancelling else { return }
        if bytes == 0 || transferStarted == nil { transferStarted = clock() }
        transferredBytes = bytes
        progress = total > 0 ? min(1, Double(bytes) / Double(total)) : nil
        message =
            "Item \(completed + 1) of \(batchCount): \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) transferred"
    }
    func disconnected() {
        localWork.cancel()
        conflict = nil
        overwriteAll = false
        dropAttempt = UUID()
        cancelling = false
        dragToken = nil
        releaseDropAccess()
        client = nil
        requestID = nil
        jobs = []
        activeJob = nil
        busy = false
        progress = nil
        resetTransferSpeed()
        requested = false
        remoteFiles = []
        clearBuffer()
        message = "Reconnect SSH to browse files."
    }
    func chooseLocalFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = localURL ?? homeURL
        panel.message =
            needsLocalAccess
            ? "Allow access to your Home folder for file transfers." : "Choose a local folder for file transfers."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scope?.stopAccessingSecurityScopedResource()
        scope = url.startAccessingSecurityScopedResource() ? url : nil
        localURL = url
        needsLocalAccess = false
        saveHomeAccess(url)
        refreshLocal()
    }
    func refreshLocal() {
        guard let localURL, !needsLocalAccess else { return }
        do {
            localFiles = sorted(
                try FileManager.default.contentsOfDirectory(
                    at: localURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                .map { url in
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    ])
                    let link = values.isSymbolicLink == true
                    return TransferFile(
                        name: url.lastPathComponent, directory: !link && values.isDirectory == true,
                        regular: !link && values.isRegularFile == true, size: UInt64(max(0, values.fileSize ?? 0)))
                })
        } catch {
            localFiles = []
            self.error = "Could not read the selected local folder. Choose it again to grant access."
        }
    }
    func open(_ file: TransferFile, local: Bool) {
        guard !busy else { return }
        if file.directory {
            if local { openLocal(file) } else { openRemote(file) }
        } else if file.regular {
            if local, let url = localURL?.appendingPathComponent(file.name) {
                if !NSWorkspace.shared.open(url) { error = "No application could open this file." }
            } else if !local {
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "Farcast-Previews", isDirectory: true
                    )
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    let url = folder.appendingPathComponent(file.name)
                    run([
                        FileJob(
                            operation: "downloadTree", source: remoteChild(file.name), destination: url.path,
                            preview: url)
                    ])
                } catch { self.error = "Could not create a local preview folder." }
            }
        }
    }
    func reveal(_ files: [TransferFile]) {
        guard let localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting(files.map { localURL.appendingPathComponent($0.name) })
    }
    func openLocal(_ file: TransferFile) {
        guard !busy, file.directory, let localURL else { return }
        self.localURL = localURL.appendingPathComponent(file.name, isDirectory: true)
        refreshLocal()
    }
    func localParent() {
        guard !busy, let localURL, canGoLocalUp else { return }
        self.localURL = localURL.deletingLastPathComponent()
        refreshLocal()
    }
    var canGoLocalUp: Bool {
        guard !needsLocalAccess, let localURL else { return false }
        return localURL.standardizedFileURL != (scope ?? homeURL).standardizedFileURL
    }
    func openRemote(_ file: TransferFile) {
        guard file.directory else { return }
        refreshRemote(path: remoteChild(file.name))
    }
    func remoteParent() {
        refreshRemote(
            path: (remotePath as NSString).deletingLastPathComponent.isEmpty
                ? "/" : (remotePath as NSString).deletingLastPathComponent)
    }
    private func remoteChild(_ name: String) -> String { Self.child(name, root: remotePath) }
    private static func child(_ name: String, root: String) -> String { root == "/" ? "/\(name)" : "\(root)/\(name)" }
    private func paths(_ files: [TransferFile], local: Bool) -> [String] {
        if local { return files.compactMap { localURL?.appendingPathComponent($0.name).path } }
        return files.map { remoteChild($0.name) }
    }
    func transfer(_ files: [TransferFile], upload: Bool) {
        guard !busy, !needsLocalAccess, let localURL, !files.isEmpty, files.allSatisfy(\.transferable) else { return }
        run(
            files.map { file in
                FileJob(
                    operation: upload ? "uploadTree" : "downloadTree",
                    source: upload ? localURL.appendingPathComponent(file.name).path : remoteChild(file.name),
                    destination: upload ? remoteChild(file.name) : localURL.appendingPathComponent(file.name).path)
            })
    }
    func copy(_ files: [TransferFile], local: Bool, cut: Bool) {
        guard !busy, !files.isEmpty, files.allSatisfy(\.transferable) else { return }
        clearBuffer()
        if local, let scope, scope.startAccessingSecurityScopedResource() { bufferScope = scope }
        buffer = FileBuffer(local: local, sources: paths(files, local: local), cut: cut)
        bufferedCount = buffer?.sources.count ?? 0
        message = "\(bufferedCount) items \(cut ? "cut" : "copied"). Choose a destination folder and Paste."
    }
    private func clearBuffer() {
        bufferScope?.stopAccessingSecurityScopedResource()
        bufferScope = nil
        buffer = nil
        bufferedCount = 0
    }
    func canPaste(local: Bool) -> Bool {
        !busy && bufferedCount > 0 && (!local || (localURL != nil && !needsLocalAccess))
            && (local && buffer?.local == true || client != nil)
    }
    var pasteMovesItems: Bool { buffer?.cut == true }
    func paste(local: Bool) {
        guard canPaste(local: local), let buffer else { return }
        let destinationRoot = local ? localURL!.path : remotePath
        run(
            buffer.sources.map { source in
                let destination = Self.child((source as NSString).lastPathComponent, root: destinationRoot)
                if buffer.local && local {
                    return FileJob(
                        operation: buffer.cut ? "move" : "copy", source: source, destination: destination,
                        local: true, cutSource: buffer.cut ? source : nil)
                }
                if !buffer.local && !local {
                    return FileJob(
                        operation: buffer.cut ? "rename" : "copyRemote", source: source, destination: destination,
                        cutSource: buffer.cut ? source : nil)
                }
                return FileJob(
                    operation: buffer.local ? "uploadTree" : "downloadTree", source: source, destination: destination,
                    move: buffer.cut, cutSource: buffer.cut ? source : nil)
            })
    }
    func copyPaths(_ files: [TransferFile], local: Bool) {
        let value = paths(files, local: local).joined(separator: "\n")
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        message = "Copied \(files.count) paths"
    }
    func rename(_ file: TransferFile, local: Bool, name: String) {
        guard validName(name), let source = paths([file], local: local).first else { return }
        let root = local ? localURL!.path : remotePath
        run([
            FileJob(
                operation: local ? "move" : "rename", source: source, destination: Self.child(name, root: root),
                local: local)
        ])
    }
    func newFolder(local: Bool, name: String) {
        guard validName(name), let root = local ? localURL?.path : remotePath else { return }
        run([
            FileJob(
                operation: "mkdir", source: Self.child(name, root: root), destination: "",
                local: local)
        ])
    }
    func delete(_ files: [TransferFile], local: Bool) {
        run(
            paths(files, local: local).map {
                FileJob(operation: local ? "trash" : "removeTree", source: $0, destination: "", local: local)
            })
    }
    private func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            error = "Enter a single file or folder name without slashes."
            return false
        }
        return true
    }
    private func run(_ work: [FileJob]) {
        guard !busy, !work.isEmpty, work.allSatisfy({ $0.local || client != nil }) else { return }
        localWork = FileWorkCancellation()
        overwriteAll = false
        conflict = nil
        jobs = work
        batchCount = work.count
        completed = 0
        requestIsListing = false
        runNext()
    }
    private func runNext() {
        guard !jobs.isEmpty else {
            busy = false
            releaseDropAccess()
            message = "Completed \(completed) items"
            refreshLocal()
            if client != nil { refreshRemote() }
            return
        }
        let job = jobs.removeFirst()
        activeJob = job
        let id = begin("Item \(completed + 1) of \(batchCount): \((job.source as NSString).lastPathComponent)")
        if job.local {
            let cancellation = localWork
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let failure = Self.performLocal(job, cancellation: cancellation)
                DispatchQueue.main.async { self.receive(id: id, result: [:], error: failure) }
            }
        } else {
            client?.fileOperation(
                job.operation, source: job.source, destination: job.destination, move: job.move, requestID: id)
        }
    }
    nonisolated private static func performLocal(_ job: FileJob, cancellation: FileWorkCancellation) -> String? {
        let manager = FileManager.default
        let source = URL(fileURLWithPath: job.source)
        let destination = URL(fileURLWithPath: job.destination)
        do {
            guard !cancellation.cancelled else { return "Operation cancelled." }
            if job.operation == "copy" || job.operation == "move" {
                let src = source.resolvingSymlinksInPath().path
                let dst = destination.resolvingSymlinksInPath().path
                guard src != dst, !dst.hasPrefix(src + "/"), !manager.fileExists(atPath: job.destination) else {
                    return "Choose a destination outside the source folder with no existing item of the same name."
                }
                if job.operation == "move" && renamex_np(job.source, job.destination, UInt32(RENAME_EXCL)) == 0 {
                    return nil
                }
                if job.operation == "move" && errno != EXDEV { throw CocoaError(.fileWriteUnknown) }
                try copyLocalTree(
                    source, destination: destination, move: job.operation == "move", cancellation: cancellation)
            } else if job.operation == "mkdir" {
                guard !manager.fileExists(atPath: job.source) else { throw CocoaError(.fileWriteFileExists) }
                try manager.createDirectory(
                    at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else if job.operation == "trash" {
                try manager.trashItem(at: source, resultingItemURL: nil)
            }
            return nil
        } catch {
            return "The local operation failed. Check access and destination names; existing items are never replaced."
        }
    }
    nonisolated private static func fingerprint(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let type = info.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { throw CocoaError(.fileReadUnsupportedScheme) }
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(type)"
    }
    nonisolated private static func copyLocalTree(
        _ source: URL, destination: URL, move: Bool, cancellation: FileWorkCancellation
    ) throws {
        let manager = FileManager.default
        var entries = [source]
        var scanError: Error?
        let rootValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if rootValues.isDirectory == true && rootValues.isSymbolicLink != true {
            guard
                let items = manager.enumerator(
                    at: source, includingPropertiesForKeys: [.isSymbolicLinkKey],
                    errorHandler: { _, error in
                        scanError = error
                        return false
                    })
            else { throw CocoaError(.fileReadUnknown) }
            for case let url as URL in items {
                guard !cancellation.cancelled, entries.count < 20000, items.level <= 64 else {
                    throw CocoaError(.userCancelled)
                }
                _ = try fingerprint(url.path)
                entries.append(url)
            }
        }
        if let scanError { throw scanError }
        let snapshots = try entries.map { try fingerprint($0.path) }
        for (index, url) in entries.enumerated() {
            guard !cancellation.cancelled, try fingerprint(url.path) == snapshots[index] else {
                throw CocoaError(.userCancelled)
            }
            let relative = url.path == source.path ? "" : String(url.path.dropFirst(source.path.count + 1))
            let target = relative.isEmpty ? destination : destination.appendingPathComponent(relative)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            if info.st_mode & S_IFMT == S_IFDIR {
                guard mkdir(target.path, 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
            } else {
                try copyLocalFile(url.path, destination: target.path, cancellation: cancellation)
            }
        }
        if move {
            guard try entries.map({ try fingerprint($0.path) }) == snapshots else { throw CocoaError(.fileReadUnknown) }
            for (index, url) in entries.enumerated().reversed() {
                guard !cancellation.cancelled else { throw CocoaError(.userCancelled) }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                let current = try fingerprint(url.path)
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard current.split(separator: ":").first == snapshots[index].split(separator: ":").first else {
                        throw CocoaError(.fileReadUnknown)
                    }
                } else {
                    guard current == snapshots[index] else { throw CocoaError(.fileReadUnknown) }
                }
                let rc = info.st_mode & S_IFMT == S_IFDIR ? rmdir(url.path) : unlink(url.path)
                guard rc == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
    nonisolated private static func copyLocalFile(
        _ source: String, destination: String, cancellation: FileWorkCancellation
    ) throws {
        let staging =
            (destination as NSString).deletingLastPathComponent + "/.farcast-transfer-" + UUID().uuidString
        let input = Darwin.open(source, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(input) }
        let output = Darwin.open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer {
            close(output)
            unlink(staging)
        }
        var initial = stat()
        guard fstat(input, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        var bytes = 0
        var buffer = [UInt8](repeating: 0, count: 32768)
        while !cancellation.cancelled {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            var offset = 0
            while offset < count && !cancellation.cancelled {
                let written = buffer.withUnsafeBytes {
                    Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += written
            }
            bytes += offset
        }
        guard !cancellation.cancelled, bytes == initial.st_size, fsync(output) == 0, link(staging, destination) == 0
        else { throw CocoaError(.fileWriteUnknown) }
    }
    func dragProvider(_ files: [TransferFile], local: Bool) -> NSItemProvider {
        let provider = NSItemProvider()
        guard !busy, !files.isEmpty, files.allSatisfy(\.transferable) else { return provider }
        let sources = paths(files, local: local)
        let token =
            draggedSources == sources && draggedLocal == local ? (dragToken ?? UUID().uuidString) : UUID().uuidString
        dragToken = token
        draggedSources = sources
        draggedLocal = local
        return NSItemProvider(object: token as NSString)
    }
    func acceptDrop(_ providers: [NSItemProvider], local: Bool, folder: String? = nil) -> Bool {
        guard !busy, !providers.isEmpty, !local || !needsLocalAccess, local || client != nil else { return false }
        let root = local ? localURL!.path : remotePath
        let destinationRoot = folder.map { Self.child($0, root: root) } ?? root
        if let internalProvider = providers.first(where: {
            !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && $0.hasItemConformingToTypeIdentifier(Self.dragType)
        }) {
            internalProvider.loadDataRepresentation(forTypeIdentifier: Self.dragType) { [weak self] data, _ in
                DispatchQueue.main.async {
                    guard let self, !self.busy, let data, let token = String(data: data, encoding: .utf8),
                        let currentToken = self.dragToken, token == currentToken
                    else {
                        return
                    }
                    let sourceLocal = self.draggedLocal
                    let work = self.draggedSources.map { source in
                        FileJob(
                            operation: sourceLocal && local
                                ? "copy" : sourceLocal ? "uploadTree" : local ? "downloadTree" : "copyRemote",
                            source: source,
                            destination: Self.child((source as NSString).lastPathComponent, root: destinationRoot),
                            local: sourceLocal && local)
                    }
                    self.dragToken = nil
                    self.run(work)
                }
            }
            return true
        }
        let external = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !external.isEmpty else { return false }
        busy = true
        message = "Preparing dropped files…"
        dropProviders = external
        dropAttempt = UUID()
        let attempt = dropAttempt
        Task { [weak self] in
            guard let self else { return }
            var sources: [URL] = []
            for provider in external {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        continuation.resume(returning: url)
                    }
                }
                if let url, url.isFileURL { sources.append(url) }
            }
            guard self.dropAttempt == attempt else { return }
            guard self.busy, self.dropProviders.count == external.count, !self.cancelling else {
                self.releaseDropAccess()
                self.busy = false
                self.cancelling = false
                return
            }
            for url in sources where url.startAccessingSecurityScopedResource() { self.dropScopes.append(url) }
            self.busy = false
            guard sources.count == external.count else {
                self.releaseDropAccess()
                self.error = "Some dropped items could not be opened. Drop files or folders from Finder."
                return
            }
            self.run(
                sources.map {
                    FileJob(
                        operation: local ? "copy" : "uploadTree", source: $0.path,
                        destination: Self.child($0.lastPathComponent, root: destinationRoot), local: local)
                })
        }
        return true
    }
    private func sorted(_ files: [TransferFile]) -> [TransferFile] {
        files.sorted {
            if $0.directory != $1.directory { return $0.directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    deinit {
        scope?.stopAccessingSecurityScopedResource()
        bufferScope?.stopAccessingSecurityScopedResource()
        for url in dropScopes { url.stopAccessingSecurityScopedResource() }
    }
}
