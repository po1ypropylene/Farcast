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
        let items = batch.files.map { url in
            let item = NSPasteboardItem()
            let provider = RDPClipboardFileProvider(batch: batch, url: url)
            item.setString("1", forType: Self.remoteFilesType)
            item.setDataProvider(provider, forTypes: [.fileURL])
            return item
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

private final class RDPClipboardFileProvider: NSObject, NSPasteboardItemDataProvider {
    private let batch: FCRDPClipboardFileBatch
    private let url: URL
    private let fulfillmentLock = NSLock()
    private var fulfilling = false
    init(batch: FCRDPClipboardFileBatch, url: URL) {
        self.batch = batch
        self.url = url
    }
    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else { return }
        fulfillmentLock.lock()
        let alreadyFulfilling = fulfilling
        fulfilling = true
        fulfillmentLock.unlock()
        guard !alreadyFulfilling else { return }
        defer {
            fulfillmentLock.lock()
            fulfilling = false
            fulfillmentLock.unlock()
        }
        let change = pasteboard?.changeCount
        batch.requestContents()
        let ready: Bool
        if Thread.isMainThread {
            // AppKit's provider contract is synchronous. Service the native event
            // loop during an actual paste so progress, disconnect and cancellation
            // still work. Never park the UI on the worker's condition variable.
            ready = MainActor.assumeIsolated { fulfillOnMainThread() }
        } else {
            ready = batch.waitUntilReady(timeout: 300)
        }
        guard ready, pasteboard?.changeCount == change else {
            batch.cancel()
            return
        }
        item.setString(url.absoluteString, forType: type)
    }

    @MainActor private func fulfillOnMainThread() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 300
        while !batch.isFinished && ProcessInfo.processInfo.systemUptime < deadline {
            autoreleasepool {
                if let event = NSApplication.shared.nextEvent(
                    matching: .any, until: Date(timeIntervalSinceNow: 0.02), inMode: .default, dequeue: true)
                {
                    NSApplication.shared.sendEvent(event)
                }
            }
        }
        return batch.waitUntilReady(timeout: 0)
    }
}
