import AppKit

private final class DelayedClipboardBatch: FCRDPClipboardFileBatch, @unchecked Sendable {
    var requested = false
    var completed = false
    var successful = true
    override func requestContents() { requested = true }
    override var isFinished: Bool { completed }
    override func waitUntilReady(timeout: TimeInterval) -> Bool { completed && successful }
}

@main struct ClipboardBridgeChecks {
    @MainActor static func main() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let bridge = RDPClipboardBridge(pasteboard: pasteboard)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = folder.appendingPathComponent("clipboard.bin")
        try! Data([0, 255, 1]).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        var text: String?
        var files: [URL]?
        bridge.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(files == [file] && text == nil)
        bridge.remoteChanged()
        bridge.receive(files: [file])
        files = nil
        bridge.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(files == nil && text == nil, "Remote files must not echo back")
        bridge.remoteChanged()
        pasteboard.clearContents()
        pasteboard.setString("new local copy", forType: .string)
        bridge.receive(files: [file])
        precondition(
            pasteboard.string(forType: .string) == "new local copy", "Late files must not overwrite a local copy")
        bridge.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(text == "new local copy")
        bridge.invalidate()
        precondition(pasteboard.string(forType: .string) == text, "User's replacement survives disconnect")
        bridge.remoteChanged()
        bridge.receive(files: [file])
        bridge.invalidate()
        precondition(pasteboard.pasteboardItems?.isEmpty != false, "Expiring staged URLs are removed")
        bridge.remoteChanged()
        bridge.receive(text: "繁體😀")
        precondition(pasteboard.string(forType: .string) == "繁體😀")
        let stage = folder.appendingPathComponent("provider")
        try! FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let stagedFile = stage.appendingPathComponent("provided.bin")
        try! Data([1, 2, 3]).write(to: stagedFile)
        bridge.remoteChanged()
        let batch = FCRDPClipboardFileBatch(root: stage, files: [stagedFile])!
        bridge.receive(batch: batch)
        text = nil
        files = nil
        bridge.reset()
        bridge.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(text == nil && files == nil, "Focus reset must not consume or echo remote file items")
        let otherSession = RDPClipboardBridge(pasteboard: pasteboard)
        otherSession.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(text == nil && files == nil, "Another RDP session must not consume remote file items")
        bridge.invalidate()
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(urls == [stagedFile], "Materialized file provider survives session disconnect")
        precondition(FileManager.default.fileExists(atPath: stagedFile.path))
        bridge.remoteChanged()
        let delayed = DelayedClipboardBatch(root: stage, files: [stagedFile])!
        bridge.receive(batch: delayed)
        bridge.reset()
        bridge.synchronize(text: { text = $0 }, files: { files = $0 })
        precondition(
            pasteboard.availableType(from: [.fileURL]) == .fileURL && !delayed.requested,
            "Copy, availability and focus changes must not materialize files")
        var heartbeat = false
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            heartbeat = true
            delayed.completed = true
        }
        let delayedURLs =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(
            delayed.requested && heartbeat && delayedURLs == [stagedFile],
            "Actual paste services UI timers while awaiting complete files")
        bridge.remoteChanged()
        let replaced = DelayedClipboardBatch(root: stage, files: [stagedFile])!
        bridge.receive(batch: replaced)
        let privateName = pasteboard.name.rawValue
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            let pasteboard = NSPasteboard(name: .init(privateName))
            pasteboard.clearContents()
            pasteboard.setString("replacement during paste", forType: .string)
            replaced.completed = true
        }
        _ = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        precondition(
            pasteboard.string(forType: .string) == "replacement during paste",
            "A reentrant local copy survives pending fulfillment")
        bridge.remoteChanged()
        let stale = DelayedClipboardBatch(root: stage, files: [stagedFile])!
        stale.completed = true
        stale.successful = false
        bridge.receive(batch: stale)
        precondition(
            pasteboard.string(forType: .string) == "replacement during paste",
            "A batch cancelled before its main-actor callback must not replace the clipboard")
        print("PASS RDP private pasteboard ownership and fulfillment checks")
    }
}
