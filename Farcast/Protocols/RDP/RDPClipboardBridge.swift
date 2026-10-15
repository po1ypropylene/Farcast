import AppKit

// Only the selected, opted-in session calls this bridge. Tests inject a private
// named pasteboard so they never inspect or replace the user's clipboard.
@MainActor final class RDPClipboardBridge {
    // A concrete marker is safe to inspect without asking a delayed provider
    // for file URLs. It also prevents echoes across session/focus changes.
    private static let remoteFilesType = NSPasteboard.PasteboardType("com.peterpo.farcast.remote-files")
    private let pasteboard: NSPasteboard
    private var observedChange = -1
    private var remoteChange = -1
    private var ownedFilesChange: Int?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func remoteChanged() {
        remoteChange = pasteboard.changeCount
        observedChange = remoteChange
    }

    func receive(text: String) {
        guard pasteboard.changeCount == remoteChange else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        observedChange = pasteboard.changeCount
        ownedFilesChange = nil
    }

    func receive(files: [URL]) {
        guard pasteboard.changeCount == remoteChange, !files.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(files as [NSURL])
        observedChange = pasteboard.changeCount
        ownedFilesChange = observedChange
    }

    func receive(batch: FCRDPClipboardFileBatch) {
        guard pasteboard.changeCount == remoteChange, !batch.files.isEmpty,
            !batch.isFinished || batch.waitUntilReady(timeout: 0)
        else { return }
        let items = (batch.files ?? []).map { _ in NSPasteboardItem() }
        let provider = RDPClipboardFileProvider(batch: batch, items: items)
        for item in items {
            item.setString("1", forType: Self.remoteFilesType)
            item.setDataProvider(provider, forTypes: [.fileURL])
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        observedChange = pasteboard.changeCount
        // Completed files belong to the pasteboard provider, beyond disconnect.
        ownedFilesChange = nil
    }

    func synchronize(text: (String) -> Void, files: ([URL]) -> Void) {
        guard pasteboard.changeCount != observedChange else { return }
        observedChange = pasteboard.changeCount
        ownedFilesChange = nil
        guard pasteboard.availableType(from: [Self.remoteFilesType]) == nil else { return }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            files(urls)
        } else {
            text(pasteboard.string(forType: .string) ?? "")
        }
    }

    func reset() { observedChange = -1 }

    func invalidate() {
        // Legacy session-owned URLs expire on disconnect. Provider-owned batches
        // remain available; a subsequent local copy always belongs to the user.
        if let ownedFilesChange, pasteboard.changeCount == ownedFilesChange { pasteboard.clearContents() }
        ownedFilesChange = nil
        remoteChange = -1
        observedChange = -1
    }
}

// One provider owns the entire batch so AppKit's ownership-end callback cannot
// retire a transfer merely because one of its items no longer needs a provider.
private final class RDPClipboardFileProvider: NSObject, NSPasteboardItemDataProvider {
    private static let fulfillmentTimeout: TimeInterval = 300
    private static let pollingInterval: TimeInterval = 0.02
    private let batch: FCRDPClipboardFileBatch
    // Do not retain the items: each item retains its provider.
    private let urls: [ObjectIdentifier: URL]
    private let fulfillmentLock = NSLock()
    private var fulfilling: Set<ObjectIdentifier> = []
    private var retired = false

    init(batch: FCRDPClipboardFileBatch, items: [NSPasteboardItem]) {
        self.batch = batch
        urls = Dictionary(uniqueKeysWithValues: zip(items, batch.files).map { (ObjectIdentifier($0), $1) })
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        fulfillmentLock.withLock { retired = true }
        // Successful batches keep their staged files; cancel is terminal only
        // for pending work and wakes background consumers immediately.
        batch.cancel()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        let identifier = ObjectIdentifier(item)
        guard type == .fileURL, let url = urls[identifier] else { return }
        let accepted = fulfillmentLock.withLock {
            !retired && fulfilling.insert(identifier).inserted
        }
        guard accepted else { return }
        defer { _ = fulfillmentLock.withLock { fulfilling.remove(identifier) } }
        let change = pasteboard?.changeCount
        batch.requestContents()
        guard waitForContents(pasteboard: pasteboard, change: change), pasteboard?.changeCount == change else {
            batch.cancel()
            return
        }
        item.setString(url.absoluteString, forType: type)
    }

    private func waitForContents(pasteboard: NSPasteboard?, change: Int?) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.fulfillmentTimeout
        while !batch.isFinished && ProcessInfo.processInfo.systemUptime < deadline {
            // Clipboard replacement cancels promptly, even if the peer never
            // replies. A final check alone would keep the old transfer alive.
            guard pasteboard?.changeCount == change else { return false }
            if Thread.isMainThread {
                MainActor.assumeIsolated { serviceNextEvent() }
            } else {
                _ = batch.waitUntilReady(timeout: Self.pollingInterval)
            }
        }
        return batch.waitUntilReady(timeout: 0)
    }

    @MainActor private func serviceNextEvent() {
        // AppKit requires synchronous URL fulfillment. Keep progress and cancel
        // actions working during actual paste; all transport work stays native.
        autoreleasepool {
            if let event = NSApplication.shared.nextEvent(
                matching: .any, until: Date(timeIntervalSinceNow: Self.pollingInterval), inMode: .default, dequeue: true
            ) {
                NSApplication.shared.sendEvent(event)
            }
        }
    }
}
