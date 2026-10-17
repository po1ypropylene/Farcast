import Foundation

/// A loss episode has three retries. Brief successful connections do not refill it.
struct RDPReconnectPolicy {
    static let delays: [TimeInterval] = [2, 5, 10]
    private(set) var attempts = 0
    private var hasConnected = false
    private var connectedSince: TimeInterval?

    mutating func connected(now: TimeInterval) {
        hasConnected = true
        connectedSince = now
    }

    mutating func nextDelay(now: TimeInterval) -> TimeInterval? {
        guard hasConnected else { return nil }
        if let connectedSince, now - connectedSince >= 60 { attempts = 0 }
        connectedSince = nil
        guard attempts < Self.delays.count else { return nil }
        let delay = Self.delays[attempts]
        attempts += 1
        return delay
    }
}
