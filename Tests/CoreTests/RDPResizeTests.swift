import Foundation
import XCTest

@testable import FarcastCore

final class RDPResizeTests: XCTestCase {
    private func request(_ width: Int, _ height: Int = 600, scale: Int = 100) -> RDPResizeRequest {
        RDPResizeRequest(width: width, height: height, scale: scale)!
    }
    func testGeometryUsesBackingOnceOnlyWhenRetinaEnabled() {
        let points = CGSize(width: 1001, height: 700)
        let backing = CGSize(width: 2002, height: 1400)
        XCTAssertEqual(
            RDPResizeRequest(points: points, backing: backing, backingScale: 2, retina: false), request(1000, 700))
        XCTAssertEqual(
            RDPResizeRequest(points: points, backing: backing, backingScale: 2, retina: true),
            request(2002, 1400, scale: 200))
        XCTAssertEqual(
            RDPResizeRequest(points: CGSize(width: 9000, height: 99), backing: backing, backingScale: 1, retina: false),
            request(8192, 200))
        XCTAssertNil(
            RDPResizeRequest(
                points: CGSize(width: CGFloat.infinity, height: 100), backing: backing, backingScale: 1, retina: false))
        XCTAssertNil(RDPResizeRequest(width: 801, height: 600, scale: 100))
    }
    func testDelayedCapabilitiesSendLatestDesiredSize() {
        var coordinator = RDPResizeCoordinator()
        XCTAssertNil(coordinator.request(request(800)))
        XCTAssertNil(coordinator.request(request(900)))
        XCTAssertEqual(coordinator.availability(true)?.request, request(900))
        XCTAssertNil(coordinator.request(request(900)))
    }
    func testMatchingInitialDesktopNeedsNoDeadlineWithOrWithoutCapabilities() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.observe(request(800).size)
        XCTAssertNil(coordinator.request(request(800)))
        XCTAssertNil(coordinator.observation)
        XCTAssertNil(coordinator.availability(true))
        XCTAssertNil(coordinator.observation)
    }
    func testDeadlineTracksOnlyCurrentUnfinishedWork() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.observe(request(640, 480).size)
        _ = coordinator.request(request(800))
        XCTAssertEqual(coordinator.observation, .availability(request(800)))
        let pending = coordinator.availability(true)!
        XCTAssertEqual(coordinator.observation, .geometry(pending))
        _ = coordinator.result(id: pending.id, submitted: true)
        _ = coordinator.observe(pending.request.size)
        XCTAssertNil(coordinator.observation)
        _ = coordinator.availability(false)
        XCTAssertNil(coordinator.observation)
        _ = coordinator.request(request(1000))
        XCTAssertNotNil(coordinator.observation)
        _ = coordinator.expire()
        XCTAssertNil(coordinator.observation)
        _ = coordinator.request(request(1000))
        XCTAssertNil(coordinator.observation)
        XCTAssertEqual(coordinator.availability(true)?.request, request(1000))
        coordinator.cancel()
        XCTAssertNil(coordinator.observation)
    }
    func testStormKeepsOnePendingAndReevaluatesAfterIntermediateGraphics() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.availability(true)
        let initial = coordinator.request(request(800))!
        for width in stride(from: 900, through: 1800, by: 2) { XCTAssertNil(coordinator.request(request(width))) }
        XCTAssertEqual(coordinator.pending, initial)
        _ = coordinator.result(id: initial.id, submitted: true)
        let newest = coordinator.observe(initial.request.size)!
        XCTAssertEqual(newest.request, request(1800))
        XCTAssertNil(coordinator.result(id: initial.id, submitted: false))
        XCTAssertEqual(coordinator.pending, newest)
        XCTAssertNil(coordinator.observe(newest.request.size))
        XCTAssertNil(coordinator.pending)
    }
    func testReturnedViewportWaitsForConflictingPendingResize() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.observe(request(800).size)
        _ = coordinator.availability(true)
        XCTAssertNil(coordinator.request(request(800)))
        let wider = coordinator.request(request(1000))!
        _ = coordinator.result(id: wider.id, submitted: true)
        XCTAssertNil(coordinator.request(request(800)))
        XCTAssertEqual(coordinator.observe(wider.request.size)?.request, request(800))
    }
    func testIgnoredIntermediateResizeDoesNotFailAnAlreadyMatchingLatestTarget() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.observe(request(800).size)
        _ = coordinator.availability(true)
        _ = coordinator.request(request(800))
        let wider = coordinator.request(request(1000))!
        _ = coordinator.result(id: wider.id, submitted: true)
        _ = coordinator.request(request(800))
        XCTAssertFalse(coordinator.isSatisfied)
        XCTAssertNil(coordinator.expire())
        XCTAssertTrue(coordinator.isSatisfied)
        XCTAssertNil(coordinator.observation)
    }
    func testIgnoredRequestExpiresWithoutResendLoopButNewIntentRetries() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.availability(true)
        let first = coordinator.request(request(1000))!
        _ = coordinator.result(id: first.id, submitted: true)
        XCTAssertNil(coordinator.expire())
        XCTAssertNil(coordinator.request(first.request))
        let smaller = coordinator.request(request(800))!
        XCTAssertNil(coordinator.result(id: smaller.id, submitted: false))
        XCTAssertNotNil(coordinator.request(first.request))
    }
    func testDPIOnlyChangeIsSentAndHandledWithoutClaimingObservedScale() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.observe(request(800).size)
        _ = coordinator.availability(true)
        let dpi = coordinator.request(request(800, scale: 200))!
        XCTAssertNil(coordinator.result(id: dpi.id, submitted: true))
        XCTAssertNil(coordinator.pending)
        XCTAssertNil(coordinator.request(dpi.request))
        XCTAssertEqual(coordinator.request(request(800, scale: 100))?.request, request(800, scale: 100))
    }
    func testChannelLossAndCancellationInvalidateLocalTokens() {
        var coordinator = RDPResizeCoordinator()
        _ = coordinator.availability(true)
        let old = coordinator.request(request(1000))!
        XCTAssertNil(coordinator.availability(false))
        XCTAssertNil(coordinator.pending)
        let fresh = coordinator.availability(true)!
        XCTAssertNotEqual(old.id, fresh.id)
        XCTAssertNil(coordinator.result(id: old.id, submitted: true))
        coordinator.cancel()
        XCTAssertNil(coordinator.result(id: fresh.id, submitted: true))
        XCTAssertNil(coordinator.desired)
    }
}
