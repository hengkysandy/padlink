// Padlink/PadlinkMacTests/ProjectSmokeTests.swift
import XCTest
import PadlinkCore

final class ProjectSmokeTests: XCTestCase {
    /// Proves the app target exists, links PadlinkCore, and can run tests.
    /// The build system is what breaks here, not this assertion.
    func testAppTargetLinksPadlinkCore() {
        XCTAssertEqual(Padlink.protocolVersion, 2)
        XCTAssertEqual(Padlink.bonjourServiceType, "_padlink._tcp")
    }
}
