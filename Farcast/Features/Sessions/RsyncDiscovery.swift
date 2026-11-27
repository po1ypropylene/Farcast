import Darwin
import Foundation

struct RsyncDiscovery {
    struct Result {
        var installs: [RsyncInstall] = []
        var notes: [String] = []
    }
    static let preference = "localRsyncPath"
    private static let lock = NSLock()
    private static var cache: (String, Result)?

    static func local(override: String, refresh: Bool) async -> Result {
        await Task.detached {
            if !refresh, let hit = lock.withLock({ cache }), hit.0 == override { return hit.1 }
            let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
            let bundled =
                Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("rsync").path ?? ""
            var paths = [
                override, bundled, "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/opt/local/bin/rsync",
                home + "/.nix-profile/bin/rsync", "/nix/var/nix/profiles/default/bin/rsync", "/usr/bin/rsync",
            ]
            if let shell = getpwuid(getuid()).map({ String(cString: $0.pointee.pw_shell) }),
                let output = Self.output(shell, ["-l", "-c", "which -a rsync"])
            {
                paths += output.components(separatedBy: .newlines)
            }
            var seen = Set<String>()
            let candidates = paths.filter { path in
                path.hasPrefix("/") && seen.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted
            }
            let result = await withTaskGroup(of: (Int, RsyncInstall?, String?).self) { group in
                for (index, path) in candidates.enumerated() {
                    group.addTask {
                        guard let text = Self.output(path, ["--version"]),
                            let install = RsyncInstall(path: path, output: text)
                        else {
                            let report = path == override || FileManager.default.fileExists(atPath: path)
                            return (index, nil, report ? "Could not run rsync at " + path : nil)
                        }
                        return (index, install, nil)
                    }
                }
                var results: [(Int, RsyncInstall?, String?)] = []
                for await value in group { results.append(value) }
                results.sort { $0.0 < $1.0 }
                return Result(
                    installs: RsyncInstall.ranked(results.compactMap { $0.1 }, override: override),
                    notes: results.compactMap { $0.2 })
            }
            lock.withLock { cache = (override, result) }
            return result
        }.value
    }

    static func verifyBundled() -> Bool {
        guard let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("rsync").path,
            let text = output(path, ["--version"]), let install = RsyncInstall(path: path, output: text)
        else { return false }
        print("Bundled rsync " + install.version)
        return !install.openRsync
    }

    private static func output(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        task.environment = environment
        task.arguments = args
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline && data.count <= 65536 {
            let n = read(fd, &bytes, bytes.count)
            if n > 0 {
                data.append(contentsOf: bytes.prefix(n))
            } else if !task.isRunning && n == 0 {
                return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            } else {
                usleep(10000)
            }
        }
        if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        task.waitUntilExit()
        return nil
    }

    static func remote(_ data: Data?, override: String?) -> Result {
        let parts = (data ?? Data()).split(separator: 0, omittingEmptySubsequences: false)
        var seen = Set<String>()
        var installs: [RsyncInstall] = []
        for i in stride(from: 1, to: parts.count - 1, by: 2) {
            let path = String(decoding: parts[i], as: UTF8.self)
            if seen.insert(path).inserted,
                let entry = RsyncInstall(path: path, output: String(decoding: parts[i + 1], as: UTF8.self))
            {
                installs.append(entry)
            }
        }
        let notes = override.flatMap { value in
            installs.contains { $0.path == value } ? nil : "Remote override could not run rsync."
        }
        return Result(installs: RsyncInstall.ranked(installs, override: override), notes: notes.map { [$0] } ?? [])
    }
}
