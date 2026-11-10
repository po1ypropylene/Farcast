import AppKit
import Foundation

@main struct ConflictOperations {
    @MainActor static func main() async {
        let files = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("conflict-data")
        try? files.removeItem(at: root)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try! files.createDirectory(at: source.appendingPathComponent("tree"), withIntermediateDirectories: true)
        try! files.createDirectory(at: destination, withIntermediateDirectories: true)
        let old = Data([1, 2, 3, 4, 5])
        let new = Data([255, 0, 128])
        let names = ["a.bin", "b.bin", "tree/nested.bin"]
        for name in names { try! old.write(to: source.appendingPathComponent(name)) }
        var progressTime = 100.0
        let controller = SFTPController(homeURL: source, requiresAccess: false, clock: { progressTime })
        var leafStarts = 0
        var measuredSpeed = false
        var fileLabels: [String] = []
        var progressAtFileStart: [Double?] = []
        var checkSingleFileBytes = false
        var singleFileByteProgress = false
        let client = FCSSHClient()
        let pin = try! String(contentsOfFile: CommandLine.arguments[3], encoding: .utf8)
        var connected = false
        var stopped = false
        var terminal = Data()
        var failures = 0
        client.onTrust = { fingerprint, _ in fingerprint == pin }
        client.onStatus = { status, _ in
            DispatchQueue.main.async {
                if status == "connected" { connected = true }
                if status == "disconnected" || status == "failed" { stopped = true }
            }
        }
        client.onData = { bytes in DispatchQueue.main.async { terminal.append(bytes) } }
        client.onFiles = { id, reply, error in
            DispatchQueue.main.async { controller.receive(id: id, result: reply, error: error) }
        }
        client.onFileProgress = { id, bytes, total in
            DispatchQueue.main.async {
                progressTime += 0.1
                controller.receiveProgress(id: id, bytes: bytes, total: total)
                if bytes == 0 {
                    fileLabels.append(controller.message)
                    if progressAtFileStart.last != controller.progress {
                        progressAtFileStart.append(controller.progress)
                    }
                    if checkSingleFileBytes && total > 0 {
                        controller.receiveProgress(id: id, bytes: 2, total: 5)
                        singleFileByteProgress = controller.progress == 0.4
                        controller.receiveProgress(id: id, bytes: bytes, total: total)
                    }
                    leafStarts += 1
                    precondition(controller.transferredBytes == 0 && controller.transferSpeed == 0)
                } else {
                    measuredSpeed = measuredSpeed || (controller.transferSpeed ?? 0) > 0
                }
            }
        }
        controller.attach(client)
        client.connectHost(
            "127.0.0.1", port: Int(CommandLine.arguments[1])!, username: "fixture", password: "fixture-password",
            privateKey: nil, authentication: "password")
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<1200 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        func check(_ pass: Bool, _ label: String) {
            print("\(pass ? "PASS" : "FAIL") SFTP conflict \(label)")
            if !pass { failures += 1 }
        }
        let selection = [
            TransferFile(name: "a.bin", directory: false, regular: true, size: 5),
            TransferFile(name: "b.bin", directory: false, regular: true, size: 5),
            TransferFile(name: "tree", directory: true, regular: false, size: 0),
        ]
        func finish(overwrite: Bool, all: Bool = false) async -> Int {
            var prompts = 0
            for _ in 0..<1200 {
                if controller.conflict != nil {
                    prompts += 1
                    controller.resolveConflict(overwrite: overwrite, all: all)
                }
                if !controller.busy { return prompts }
                try? await Task.sleep(for: .milliseconds(25))
            }
            controller.cancel()
            check(false, "transfer-timeout")
            return prompts
        }
        func bytesEqual(_ expected: Data, at directory: URL) -> Bool {
            names.allSatisfy { (try? Data(contentsOf: directory.appendingPathComponent($0))) == expected }
        }
        await wait { connected || stopped }
        controller.refreshRemote()
        await wait { !controller.busy }
        controller.transfer(selection, upload: true)
        await wait { !controller.busy }
        check(controller.error == nil, "seed-upload")
        check(progressAtFileStart == [0, 1.0 / 3, 2.0 / 3], "batch-progress-counts-files-across-jobs")
        check(leafStarts == 3 && measuredSpeed && controller.transferSpeed == nil, "recursive-upload-speed-resets")
        controller.receiveProgress(id: "obsolete-request", bytes: 1000, total: 1000)
        check(controller.transferSpeed == nil, "stale-progress-ignored")
        checkSingleFileBytes = true
        controller.transfer([selection[0]], upload: true)
        _ = await finish(overwrite: true)
        check(singleFileByteProgress && controller.error == nil, "single-upload-progress-remains-byte-based")
        checkSingleFileBytes = false
        let counted = source.appendingPathComponent("counted")
        try! files.createDirectory(
            at: counted.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
        for name in ["one.bin", "nested/two.bin", "nested/three.bin"] {
            try! new.write(to: counted.appendingPathComponent(name))
        }
        try! Data().write(to: counted.appendingPathComponent("zero.bin"))
        let folder = TransferFile(name: "counted", directory: true, regular: false, size: 0)
        fileLabels = []
        progressAtFileStart = []
        controller.transfer([folder], upload: true)
        await wait { !controller.busy }
        check(
            controller.error == nil
                && (1...4).allSatisfy { number in
                    fileLabels.contains { $0.hasPrefix("File \(number) of 4:") }
                }, "preflight-upload-file-count-excludes-folders")
        check(progressAtFileStart == [0, 0.25, 0.5, 0.75], "recursive-upload-progress-includes-empty-file")
        controller.localURL = destination
        fileLabels = []
        progressAtFileStart = []
        controller.transfer([folder], upload: false)
        await wait { !controller.busy }
        check(
            controller.error == nil
                && (1...4).allSatisfy { number in
                    fileLabels.contains { $0.hasPrefix("File \(number) of 4:") }
                }, "preflight-download-file-count-includes-empty-file")
        check(
            (try? Data(contentsOf: destination.appendingPathComponent("counted/nested/two.bin"))) == new,
            "counted-download-byte-equality")
        check(progressAtFileStart == [0, 0.25, 0.5, 0.75], "recursive-download-progress-counts-files")
        checkSingleFileBytes = true
        singleFileByteProgress = false
        controller.transfer([selection[0]], upload: false)
        await wait { !controller.busy }
        check(singleFileByteProgress && controller.error == nil, "single-download-progress-remains-byte-based")
        checkSingleFileBytes = false
        try! files.removeItem(at: destination.appendingPathComponent("a.bin"))
        let previousMessage = controller.message
        controller.receiveTransferItem(id: "obsolete-request", current: 9, total: 10)
        check(controller.message == previousMessage, "stale-file-count-ignored")
        controller.localURL = source
        fileLabels = []
        controller.transfer([selection[2], folder], upload: true)
        _ = await finish(overwrite: true, all: true)
        check(
            controller.error == nil
                && (1...5).allSatisfy { number in
                    fileLabels.contains { $0.hasPrefix("File \(number) of 5:") }
                }, "combined-recursive-upload-count-across-selected-folders")
        controller.localURL = destination
        fileLabels = []
        controller.transfer([selection[2], folder], upload: false)
        _ = await finish(overwrite: true, all: true)
        check(
            controller.error == nil
                && (1...5).allSatisfy { number in
                    fileLabels.contains { $0.hasPrefix("File \(number) of 5:") }
                }, "combined-recursive-download-count-across-selected-folders")
        try! files.removeItem(at: destination.appendingPathComponent("tree"))
        controller.localURL = source
        for name in names { try! new.write(to: source.appendingPathComponent(name)) }
        controller.transfer(selection, upload: true)
        await wait { controller.conflict != nil || !controller.busy }
        check(controller.conflict?.name == "a.bin", "upload-pauses-before-overwrite")
        client.send(Data("conflict-terminal-marker\n".utf8))
        await wait { String(decoding: terminal, as: UTF8.self).contains("conflict-terminal-marker") }
        check(String(decoding: terminal, as: UTF8.self).contains("conflict-terminal-marker"), "terminal-during-prompt")
        let uploadPrompts = await finish(overwrite: true)
        check(uploadPrompts == 3 && controller.error == nil, "overwrite-one-prompts-for-each-nested-file")
        controller.localURL = destination
        controller.transfer(selection, upload: false)
        await wait { !controller.busy }
        check(controller.error == nil && bytesEqual(new, at: destination), "upload-replacements-byte-equality")
        for name in names { try! old.write(to: destination.appendingPathComponent(name)) }
        controller.transfer(selection, upload: false)
        let downloadPrompts = await finish(overwrite: true, all: true)
        check(
            downloadPrompts == 1 && controller.error == nil && bytesEqual(new, at: destination),
            "download-overwrite-all-batch-and-nested")
        controller.transfer(selection, upload: false)
        await wait { controller.conflict != nil || !controller.busy }
        check(controller.conflict != nil, "overwrite-all-resets-next-batch")
        let stopPrompts = await finish(overwrite: false)
        check(
            stopPrompts == 1 && bytesEqual(new, at: destination) && !stopped,
            "stop-entire-batch-retains-files-and-session")
        controller.localURL = source
        controller.transfer(selection, upload: true)
        let allUpload = await finish(overwrite: true, all: true)
        check(allUpload == 1 && controller.error == nil, "upload-overwrite-all-across-jobs")
        controller.localURL = destination
        for name in names { try! old.write(to: destination.appendingPathComponent(name)) }
        controller.transfer(selection, upload: false)
        let individualDownload = await finish(overwrite: true)
        check(individualDownload == 3 && bytesEqual(new, at: destination), "download-overwrite-one")
        let unsupported = TransferFile(name: "no-atomic.bin", directory: false, regular: true, size: 5)
        controller.localURL = source
        try! old.write(to: source.appendingPathComponent(unsupported.name))
        controller.transfer([unsupported], upload: true)
        await wait { !controller.busy }
        try! new.write(to: source.appendingPathComponent(unsupported.name))
        controller.transfer([unsupported], upload: true)
        let unsupportedPrompts = await finish(overwrite: true)
        check(unsupportedPrompts == 1 && controller.error != nil, "unsupported-atomic-replace-reports-error")
        controller.error = nil
        controller.localURL = destination
        controller.transfer([unsupported], upload: false)
        await wait { !controller.busy }
        check(
            (try? Data(contentsOf: destination.appendingPathComponent(unsupported.name))) == old,
            "unsupported-atomic-replace-retains-original")
        check(
            !controller.remoteFiles.contains { $0.name.hasPrefix(".farcast-transfer-") },
            "no-remote-staging-leftovers")
        let cancellable = TransferFile(name: "slow-upload.bin", directory: false, regular: true, size: 5)
        controller.localURL = source
        try! old.write(to: source.appendingPathComponent(cancellable.name))
        controller.transfer([cancellable], upload: true)
        await wait { !controller.busy }
        try! Data(repeating: 171, count: 32 * 1024 * 1024).write(to: source.appendingPathComponent(cancellable.name))
        controller.transfer([cancellable], upload: true)
        await wait { controller.conflict != nil || !controller.busy }
        controller.resolveConflict(overwrite: true)
        await wait { controller.progress != nil || !controller.busy }
        check(controller.busy && controller.progress != nil, "overwrite-upload-active-before-cancel")
        controller.cancel()
        await wait { !controller.busy }
        controller.localURL = destination
        controller.transfer([cancellable], upload: false)
        await wait { !controller.busy }
        check(
            controller.error == nil && !stopped
                && (try? Data(contentsOf: destination.appendingPathComponent(cancellable.name))) == old,
            "cancel-overwrite-upload-retains-original-and-session")
        check(
            !controller.remoteFiles.contains { $0.name.hasPrefix(".farcast-transfer-") },
            "cancel-removes-remote-staging")
        try! files.removeItem(at: destination.appendingPathComponent("a.bin"))
        try! files.createSymbolicLink(
            at: destination.appendingPathComponent("a.bin"), withDestinationURL: source.appendingPathComponent("a.bin"))
        controller.transfer([selection[0]], upload: false)
        await wait { !controller.busy }
        check(
            controller.error != nil && controller.conflict == nil
                && (try? Data(contentsOf: source.appendingPathComponent("a.bin"))) == new, "destination-link-refused")
        controller.error = nil
        controller.localURL = source
        controller.transfer([selection[0]], upload: true)
        await wait { controller.conflict != nil || !controller.busy }
        client.disconnect()
        controller.disconnected()
        await wait { stopped }
        check(controller.conflict == nil && !controller.busy && stopped, "disconnect-clears-prompt")
        let remaining = (try? files.subpathsOfDirectory(atPath: destination.path)) ?? []
        check(!remaining.contains { $0.contains(".farcast-transfer-") }, "no-local-staging-leftovers")
        if failures > 0 { exit(1) }
    }
}
