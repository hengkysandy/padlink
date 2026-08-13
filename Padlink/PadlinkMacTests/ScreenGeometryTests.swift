// Padlink/PadlinkMacTests/ScreenGeometryTests.swift
import XCTest
@testable import PadlinkMac

final class ScreenGeometryTests: XCTestCase {
    func testPrimaryScreenConvertsToOriginZero() {
        let converted = ScreenGeometry.topLeftFrames(
            fromBottomLeft: [CGRect(x: 0, y: 0, width: 1440, height: 900)],
            primaryHeight: 900
        )
        XCTAssertEqual(converted, [CGRect(x: 0, y: 0, width: 1440, height: 900)])
    }

    func testScreenAbovePrimaryGetsNegativeTopLeftY() {
        // A second display sitting above the primary one. In bottom-left
        // coordinates its origin.y is positive; in top-left it is negative.
        let converted = ScreenGeometry.topLeftFrames(
            fromBottomLeft: [
                CGRect(x: 0, y: 0, width: 1440, height: 900),
                CGRect(x: 0, y: 900, width: 1920, height: 1080)
            ],
            primaryHeight: 900
        )
        XCTAssertEqual(converted[1], CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    }

    func testClampKeepsAPointInsideTheScreen() {
        let geometry = ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        XCTAssertEqual(geometry.clamp(CGPoint(x: 700, y: 400)), CGPoint(x: 700, y: 400))
    }

    func testClampPullsAPointBackOntoTheScreen() {
        let geometry = ScreenGeometry(topLeftFrames: [CGRect(x: 0, y: 0, width: 1440, height: 900)])
        let clamped = geometry.clamp(CGPoint(x: 5000, y: -200))
        // Tight tolerance on purpose: 1439 (maxX - 1, staying inside
        // CGRect.contains, which excludes the max edge) and 1440 (maxX)
        // differ by exactly 1, so accuracy: 1 would accept either.
        XCTAssertEqual(clamped.x, 1439, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0, accuracy: 0.001)
    }

    func testAPointOnASecondScreenIsLeftAlone() {
        let geometry = ScreenGeometry(topLeftFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        ])
        let point = CGPoint(x: 2000, y: 500)
        XCTAssertEqual(geometry.clamp(point), point)
    }

    func testAPointInTheGapSnapsToTheNearestScreen() {
        // Two screens of different heights side by side leave a gap below the
        // shorter one. A point there belongs to no screen and must snap.
        let geometry = ScreenGeometry(topLeftFrames: [
            CGRect(x: 0, y: 0, width: 1440, height: 900),
            CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        ])
        let inGap = CGPoint(x: 700, y: 1000)
        let clamped = geometry.clamp(inGap)
        XCTAssertEqual(clamped.x, 700, accuracy: 1)
        XCTAssertEqual(clamped.y, 899, accuracy: 1)
    }

    func testAPointInTheGapSnapsToTheNearerScreenEvenWhenListedSecond() {
        // Same two screens and the same gap point as
        // testAPointInTheGapSnapsToTheNearestScreen, but listed in the
        // opposite order. The geometrically nearer screen (the small one,
        // distance 101 to its boundary) is now second in the array, and the
        // farther one (distance 740) is first. An implementation that picks
        // the first candidate without comparing distances would return the
        // farther screen's point instead.
        let geometry = ScreenGeometry(topLeftFrames: [
            CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            CGRect(x: 0, y: 0, width: 1440, height: 900)
        ])
        let inGap = CGPoint(x: 700, y: 1000)
        let clamped = geometry.clamp(inGap)
        XCTAssertEqual(clamped.x, 700, accuracy: 1)
        XCTAssertEqual(clamped.y, 899, accuracy: 1)
    }

    func testNoScreensReturnsThePointUnchanged() {
        let geometry = ScreenGeometry(topLeftFrames: [])
        let point = CGPoint(x: 10, y: 10)
        XCTAssertEqual(geometry.clamp(point), point)
    }
}
