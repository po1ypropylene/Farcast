import AppKit
import Foundation

@main struct LocalOperations {
    @MainActor static func main() async {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("local-operations-data")
        let files = FileManager.default
        try? files.removeItem(at: root)
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try! files.createDirectory(at: source.appendingPathComponent("tree/nested"), withIntermediateDirectories: true)
        try! files.createDirectory(at: source.appendingPathComponent("tree/empty"), withIntermediateDirectories: true)
        try! files.createDirectory(at: destination, withIntermediateDirectories: true)
        let bytes = Data([0, 255, 2, 128, 42])
        try! bytes.write(to: source.appendingPathComponent("tree/nested/世界.bin"))
        try! bytes.write(to: source.appendingPathComponent("one.bin"))
        let tree = TransferFile(name: "tree", directory: true, regular: false, size: 0)
        let one = TransferFile(name: "one.bin", directory: false, regular: true, size: 5)
        let controller = SFTPController(homeURL: source, requiresAccess: false)
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL") SFTP local \(name)")
            if !passed { failures += 1 }
        }
        func finish() async {
            for _ in 0..<400 {
                if !controller.busy { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        controller.refreshLocal(reportRefresh: true)
        check(controller.message.contains("Local Mac refreshed"), "refresh-reports-completion-with-unchanged-files")
        controller.localURL = source
        controller.copy([tree, one], local: true, cut: false)
        controller.localURL = destination
        controller.paste(local: true)
        await finish()
        check(
            controller.error == nil
                && (try? Data(contentsOf: destination.appendingPathComponent("tree/nested/世界.bin"))) == bytes
                && files.fileExists(atPath: destination.appendingPathComponent("tree/empty").path)
                && (try? Data(contentsOf: destination.appendingPathComponent("one.bin"))) == bytes,
            "multi-copy-recursive")
        controller.localURL = source
        controller.copy([one], local: true, cut: true)
        controller.localURL = destination
        controller.paste(local: true)
        await finish()
        check(
            controller.error != nil && files.fileExists(atPath: source.appendingPathComponent("one.bin").path)
                && controller.bufferedCount == 1, "failed-cut-retains-source-and-buffer")
        controller.rename(one, local: true, name: "renamed.bin")
        await finish()
        check(
            controller.error == nil && files.fileExists(atPath: destination.appendingPathComponent("renamed.bin").path),
            "rename")
        controller.localURL = source
        controller.copy([one], local: true, cut: true)
        controller.localURL = destination
        controller.paste(local: true)
        await finish()
        check(
            controller.error == nil && !files.fileExists(atPath: source.appendingPathComponent("one.bin").path)
                && (try? Data(contentsOf: destination.appendingPathComponent("one.bin"))) == bytes
                && controller.bufferedCount == 0, "cut-paste")
        controller.newFolder(local: true, name: "new-folder")
        await finish()
        check(
            controller.error == nil && files.fileExists(atPath: destination.appendingPathComponent("new-folder").path),
            "new-folder")
        controller.localURL = source
        controller.copy([tree], local: true, cut: false)
        controller.localURL = source.appendingPathComponent("tree")
        controller.paste(local: true)
        await finish()
        check(
            controller.error != nil && !files.fileExists(atPath: source.appendingPathComponent("tree/tree").path),
            "self-descendant-refused")
        try! files.createSymbolicLink(at: source.appendingPathComponent("tree/link"), withDestinationURL: destination)
        controller.localURL = source
        controller.copy([tree], local: true, cut: false)
        let linkedDestination = root.appendingPathComponent("linked-destination")
        try! files.createDirectory(at: linkedDestination, withIntermediateDirectories: true)
        controller.localURL = linkedDestination
        controller.paste(local: true)
        await finish()
        check(
            controller.error != nil && !files.fileExists(atPath: linkedDestination.appendingPathComponent("tree").path),
            "link-preflight")
        let large = TransferFile(name: "large.bin", directory: false, regular: true, size: 16 * 1024 * 1024)
        try! Data(repeating: 7, count: 16 * 1024 * 1024).write(to: destination.appendingPathComponent(large.name))
        controller.localURL = destination
        controller.copy([large], local: true, cut: false)
        controller.localURL = linkedDestination
        controller.paste(local: true)
        controller.disconnected()
        try? await Task.sleep(for: .milliseconds(100))
        check(!files.fileExists(atPath: linkedDestination.appendingPathComponent(large.name).path), "cancel-local-work")
        if failures > 0 { exit(1) }
    }
}
