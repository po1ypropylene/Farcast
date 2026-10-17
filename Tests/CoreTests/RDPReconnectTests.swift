import XCTest

@testable import FarcastCore

final class RDPReconnectTests: XCTestCase {
    func testInitialFailureDoesNotRetry() {
        var policy = RDPReconnectPolicy()
        XCTAssertNil(policy.nextDelay(now: 100))
        XCTAssertEqual(policy.attempts, 0)
    }

    func testThreeRetriesAndFlappingDoesNotRefillBudget() {
        var policy = RDPReconnectPolicy()
        policy.connected(now: 0)
        XCTAssertEqual(policy.nextDelay(now: 10), 2)
        XCTAssertEqual(policy.nextDelay(now: 15), 5)
        policy.connected(now: 20)
        XCTAssertEqual(policy.nextDelay(now: 30), 10)
        policy.connected(now: 40)
        XCTAssertNil(policy.nextDelay(now: 50))
        XCTAssertEqual(policy.attempts, 3)
    }

    func testStableConnectionStartsNewLossEpisode() {
        var policy = RDPReconnectPolicy()
        policy.connected(now: 0)
        XCTAssertEqual(policy.nextDelay(now: 2), 2)
        policy.connected(now: 4)
        XCTAssertEqual(policy.nextDelay(now: 64), 2)
        XCTAssertEqual(policy.nextDelay(now: 130), 5)
    }
}
