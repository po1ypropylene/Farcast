import AppKit
import Foundation

// No network or user storage: replies are explicit, and request counts prove cache reuse.
private final class BrowsingClient: FCSSHClient {
    var listings: [(path: String, id: String)] = []
    var operations: [String] = []
    override func listDirectory(_ path: String, requestID: String) {
        listings.append((path, requestID))
    }
    override func fileOperation(
        _ kind: String, source: String, destination: String, move: Bool, requestID: String
    ) {
        operations.append(requestID)
    }
    override func cancelFiles() {}
}

@main struct BrowsingChecks {
    @MainActor static func main() {
        var now = 100.0
        let controller = SFTPController(clock: { now })
        let client = BrowsingClient()
        controller.attach(client)
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            print("PASS SFTP browsing \(label)")
        }
        func reply(_ path: String, names: [String] = ["folder", "Résumé.TXT"], error: String? = nil) {
            controller.receive(
                id: client.listings.last!.id,
                result: [
                    "path": path,
                    "entries": names.map { ["name": $0, "directory": $0 == "folder", "regular": $0 != "folder"] },
                ], error: error)
        }
        func visit(_ path: String, names: [String] = ["folder", "Résumé.TXT"]) {
            controller.navigateRemote(path: path)
            if controller.busy { reply(path, names: names) }
        }
        controller.showFiles()
        reply("/home")
        check(!controller.canGoRemoteBack && !controller.canGoRemoteForward, "initial-history")
        visit("/home/folder")
        let count = client.listings.count
        controller.remoteBack()
        check(
            controller.remotePath == "/home" && !controller.busy && client.listings.count == count
                && controller.canGoRemoteForward && controller.message.contains("cached"), "back-reuses-listing")
        controller.remoteForward()
        check(controller.remotePath == "/home/folder" && client.listings.count == count, "forward-reuses-listing")
        controller.remoteBack()
        visit("/other")
        check(!controller.canGoRemoteForward, "new-visit-discards-forward-history")
        controller.navigateRemote(path: "/missing")
        reply("/missing", error: "Synthetic missing folder")
        check(controller.remotePath == "/other" && !controller.canGoRemoteForward, "failed-visit-preserves-history")
        controller.remoteBack()
        check(controller.remotePath == "/home" && controller.error == nil, "back-after-failed-visit")
        controller.refreshRemote()
        check(controller.busy && client.listings.count == count + 3, "refresh-bypasses-cache")
        reply("/home", names: ["new.bin"])
        check(controller.remoteFiles.map(\.name) == ["new.bin"], "refresh-replaces-snapshot")
        visit("/other")
        now += 30
        controller.remoteBack()
        check(controller.busy, "expired-cache-requires-request")
        reply("/home")
        controller.remoteForward()
        reply("/other")
        controller.newFolder(local: false, name: "created")
        controller.receive(id: client.operations.last!, result: [:], error: "Synthetic write failure")
        controller.remoteBack()
        check(controller.busy, "failed-mutation-invalidates-other-folders")
        reply("/home")
        controller.remoteForward()
        reply("/other")
        controller.newFolder(local: false, name: "created")
        controller.receive(id: client.operations.last!, result: [:], error: nil)
        check(controller.busy && client.listings.last?.path == "/other", "successful-mutation-refreshes-current-folder")
        reply("/other")
        controller.remoteBack()
        check(controller.busy, "successful-mutation-invalidates-other-folders")
        reply("/home")

        for index in 0..<17 { visit("/cache-\(index)") }
        controller.navigateRemote(path: "/cache-0")
        check(controller.busy, "least-recent-folder-evicted")
        reply("/cache-0")
        controller.navigateRemote(path: "/cache-16")
        check(!controller.busy, "recent-folder-retained")
        let largeNames = (0..<9000).map { "\($0)-" + String(repeating: "x", count: 450) }
        visit("/too-large", names: largeNames)
        visit("/cache-16")
        controller.navigateRemote(path: "/too-large")
        check(controller.busy, "oversized-listing-not-retained")
        reply("/too-large", names: largeNames)
        let mediumNames = (0..<2400).map { "\($0)-" + String(repeating: "x", count: 450) }
        for index in 0..<4 { visit("/budget-\(index)", names: mediumNames) }
        controller.navigateRemote(path: "/budget-0")
        check(controller.busy, "combined-byte-budget-evicts-oldest-listing")
        reply("/budget-0", names: mediumNames)
        controller.navigateRemote(path: "/budget-3")
        check(!controller.busy, "combined-byte-budget-retains-recent-listing")
        for index in 0..<40 { visit("/history-\(index)") }
        var steps = 0
        while controller.canGoRemoteBack {
            controller.remoteBack()
            if controller.busy { reply(client.listings.last!.path) }
            steps += 1
        }
        check(steps == 31 && controller.remotePath == "/history-8", "history-bounded-to-32-folders")
        let oldID = client.listings.last!.id
        controller.disconnected()
        controller.receive(id: oldID, result: ["path": "/stale"], error: nil)
        check(controller.remoteFiles.isEmpty && !controller.canGoRemoteBack, "disconnect-clears-and-rejects-late-reply")
        controller.attach(client)
        controller.navigateRemote(path: "/history-8")
        check(controller.busy && !controller.canGoRemoteBack, "reconnect-discards-cache-and-history")
        let pendingID = client.listings.last!.id
        controller.cancel()
        controller.receive(id: pendingID, result: ["path": "/cancelled"], error: nil)
        check(!controller.busy && controller.remotePath == ".", "cancelled-navigation-never-commits")
        let files = [
            TransferFile(name: "Résumé.TXT", directory: false, regular: true, size: 1),
            TransferFile(name: "folder", directory: true, regular: false, size: 0),
        ]
        check(
            SFTPController.filteredFiles(files, matching: "resume.txt") == [files[0]],
            "case-and-accent-insensitive-filter")
        check(SFTPController.filteredFiles(files, matching: "") == files, "empty-filter-retains-order")
        check(SFTPController.filteredFiles(files, matching: "absent").isEmpty, "filter-no-match")
    }
}
