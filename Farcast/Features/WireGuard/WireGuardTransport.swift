import Foundation
import Security

/// One helper/device per saved profile, with independently cancellable session leases.
/// Blocking pipe work is performed on protocol workers, never on the main actor.
final class WireGuardTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var lease: (UUID, String)?
    private static let registryLock = NSLock()
    private static var helpers: [UUID: Helper] = [:]
    private static var shuttingDown = false
    private static let processes = DispatchGroup()

    private struct Request: Encodable {
        var command = "open"
        let configuration: WireGuardConfiguration
        let privateKey: String
        let presharedKey: String
        let host: String
        let port: Int
        let token: String
    }
    private final class Helper: @unchecked Sendable {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let configuration: WireGuardConfiguration
        let privateKey: String
        let presharedKey: String
        var callbacks: [String: @Sendable () -> Void] = [:]
        private let shutdownLock = NSLock()
        private var shutdownStarted = false
        init(configuration: WireGuardConfiguration, credential: ConnectionCredential) throws {
            self.configuration = configuration
            privateKey = credential.wireGuardPrivateKey ?? ""
            presharedKey = credential.wireGuardPresharedKey ?? ""
            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "FarcastWireGuard") else {
                throw WireGuardError.helperUnavailable
            }
            process.executableURL = executable
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
        }
        func send(_ request: Request) throws {
            var payload = try JSONEncoder().encode(request)
            payload.append(10)
            try stdin.fileHandleForWriting.write(contentsOf: payload)
        }
        func ready(cancelStartup: Bool, isCancelled: @escaping @Sendable () -> Bool) throws -> Int {
            let cancellation = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
            cancellation.schedule(deadline: .now(), repeating: .milliseconds(100))
            cancellation.setEventHandler { [weak self] in
                if cancelStartup && isCancelled() { self?.shutdown() }
            }
            cancellation.resume()
            defer { cancellation.cancel() }
            let watchdog = DispatchWorkItem { [weak self] in self?.shutdown() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
            defer { watchdog.cancel() }
            let started = ProcessInfo.processInfo.systemUptime
            var response = Data()
            while response.count < 256 {
                guard let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                    if isCancelled() { throw CancellationError() }
                    throw ProcessInfo.processInfo.systemUptime - started >= 14
                        ? WireGuardError.startupTimeout : WireGuardError.initialization
                }
                if byte.first == 10 { break }
                response.append(byte)
            }
            guard let ready = try? JSONDecoder().decode(WireGuardStartupResponse.self, from: response) else {
                throw WireGuardError.initialization
            }
            return try ready.listenerPort()
        }
        func shutdown() {
            shutdownLock.lock()
            guard !shutdownStarted else {
                shutdownLock.unlock()
                return
            }
            shutdownStarted = true
            shutdownLock.unlock()
            try? stdin.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        deinit {
            shutdown()
            try? stdout.fileHandleForReading.close()
        }
    }
    func start(
        id: UUID, configuration: WireGuardConfiguration, credential: ConnectionCredential, host: String, port: Int,
        onExit: @escaping @Sendable () -> Void
    ) throws -> (port: Int, token: String) {
        guard let privateKey = credential.wireGuardPrivateKey, WireGuardConfiguration.validKey(privateKey) else {
            throw WireGuardError.missingKeys
        }
        guard configuration.validationMessage == nil else { throw WireGuardError.invalidConfiguration }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WireGuardError.transport
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        if stopped {
            lock.unlock()
            throw CancellationError()
        }
        lease = (id, token)
        lock.unlock()
        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        guard !Self.shuttingDown else { throw CancellationError() }
        let helper: Helper
        if let active = Self.helpers[id] {
            guard active.configuration == configuration, active.privateKey == privateKey,
                active.presharedKey == credential.wireGuardPresharedKey ?? ""
            else { throw WireGuardError.profileInUse }
            helper = active
        } else {
            helper = try Helper(configuration: configuration, credential: credential)
            helper.process.terminationHandler = { [weak helper] _ in
                Self.processes.leave()
                guard let helper else { return }
                DispatchQueue.global().async {
                    Self.registryLock.lock()
                    let callbacks = helper.callbacks.values.map { $0 }
                    if Self.helpers[id] === helper { Self.helpers.removeValue(forKey: id) }
                    Self.registryLock.unlock()
                    for callback in callbacks { callback() }
                }
            }
            Self.processes.enter()
            do { try helper.process.run() } catch {
                Self.processes.leave()
                throw WireGuardError.helperLaunch
            }
            Self.helpers[id] = helper
        }
        helper.callbacks[token] = onExit
        let request = Request(
            configuration: configuration, privateKey: privateKey,
            presharedKey: credential.wireGuardPresharedKey ?? "", host: host, port: port, token: token)
        var receivedReady = false
        do {
            try helper.send(request)
            let localPort = try helper.ready(cancelStartup: helper.callbacks.count == 1) { [weak self] in
                guard let self else { return true }
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.stopped
            }
            receivedReady = true
            lock.lock()
            let cancelled = stopped
            lock.unlock()
            if cancelled { throw CancellationError() }
            return (localPort, token)
        } catch {
            helper.callbacks.removeValue(forKey: token)
            if receivedReady, !helper.callbacks.isEmpty {
                try? helper.send(
                    Request(
                        command: "close", configuration: configuration, privateKey: "", presharedKey: "", host: "",
                        port: 0, token: token))
            } else {
                let callbacks = helper.callbacks.values.map { $0 }
                helper.callbacks.removeAll()
                helper.shutdown()
                Self.helpers.removeValue(forKey: id)
                DispatchQueue.global().async { for callback in callbacks { callback() } }
            }
            if error is CancellationError { throw error }
            throw (error as? WireGuardError) ?? WireGuardError.initialization
        }
    }
    func stop() {
        lock.lock()
        stopped = true
        let released = lease
        lease = nil
        lock.unlock()
        guard let (id, token) = released else { return }
        DispatchQueue.global().async {
            Self.registryLock.lock()
            defer { Self.registryLock.unlock() }
            guard let helper = Self.helpers[id] else { return }
            helper.callbacks.removeValue(forKey: token)
            if helper.callbacks.isEmpty {
                Self.helpers.removeValue(forKey: id)
                helper.shutdown()
            } else {
                let request = Request(
                    command: "close", configuration: helper.configuration, privateKey: "", presharedKey: "", host: "",
                    port: 0, token: token)
                do { try helper.send(request) } catch { helper.shutdown() }
            }
        }
    }
    /// Permanently rejects new leases and waits for every launched helper to exit,
    /// including helpers already removed from the registry by their last lease.
    static func shutdownAll(completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            registryLock.lock()
            shuttingDown = true
            let active = Array(helpers.values)
            helpers.removeAll()
            for helper in active {
                helper.callbacks.removeAll()
                helper.shutdown()
            }
            registryLock.unlock()
            processes.notify(queue: .global(qos: .userInitiated), execute: completion)
        }
    }
    deinit { stop() }
}
