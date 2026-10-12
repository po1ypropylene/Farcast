import Foundation

@main struct LifecycleCheck {
    static func reachable(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
    static func waitClosed(_ port: Int) -> Bool {
        for _ in 0..<100 {
            if !reachable(port) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }
    static func main() throws {
        var configuration = WireGuardConfiguration()
        configuration.addresses = "10.111.0.2/32"
        configuration.publicKey = Data(repeating: 9, count: 32).base64EncodedString()
        configuration.endpoint = "127.0.0.1:51829"
        configuration.allowedIPs = "10.111.0.1/32"
        configuration.keepalive = 0
        let credential = ConnectionCredential(wireGuardPrivateKey: Data(repeating: 7, count: 32).base64EncodedString())
        let id = UUID()
        let first = WireGuardTransport()
        let second = WireGuardTransport()
        let endpoint1 = try first.start(
            id: id, configuration: configuration, credential: credential, host: "10.111.0.1", port: 22, onExit: {})
        let endpoint2 = try second.start(
            id: id, configuration: configuration, credential: credential, host: "10.111.0.1", port: 3389, onExit: {})
        first.stop()
        guard waitClosed(endpoint1.port), reachable(endpoint2.port) else { throw WireGuardError.transport }
        let changed = WireGuardTransport()
        configuration.mtu = 1400
        do {
            _ = try changed.start(
                id: id, configuration: configuration, credential: credential, host: "10.111.0.1", port: 3389, onExit: {}
            )
            throw WireGuardError.transport
        } catch WireGuardError.profileInUse {}
        changed.stop()
        second.stop()
        guard waitClosed(endpoint2.port) else { throw WireGuardError.transport }
        let cancelled = WireGuardTransport()
        cancelled.stop()
        do {
            _ = try cancelled.start(
                id: UUID(), configuration: configuration, credential: credential, host: "10.111.0.1", port: 3389,
                onExit: {})
            throw WireGuardError.transport
        } catch is CancellationError {}
        print(
            "PASS Swift tunnel lifecycle: mixed SSH/RDP destination leases, independent cleanup, changed-profile refusal, cancellation"
        )

        let sharedID = UUID()
        let transports = [WireGuardTransport(), WireGuardTransport(), WireGuardTransport()]
        let ports = try transports.enumerated().map { index, transport in
            try transport.start(
                id: index < 2 ? sharedID : UUID(), configuration: configuration, credential: credential,
                host: "10.111.0.1", port: 3389, onExit: {}
            ).port
        }
        transports[2].stop()
        let exited = DispatchSemaphore(value: 0)
        WireGuardTransport.shutdownAll { exited.signal() }
        guard exited.wait(timeout: .now() + 5) == .success, ports.allSatisfy({ !reachable($0) }) else {
            throw WireGuardError.transport
        }
        do {
            _ = try WireGuardTransport().start(
                id: UUID(), configuration: configuration, credential: credential, host: "10.111.0.1", port: 3389,
                onExit: {})
            throw WireGuardError.transport
        } catch is CancellationError {}
        for transport in transports { transport.stop() }
        print("PASS app shutdown waits for shared and already-stopping helpers and rejects new leases")
    }
}
