// Padlink/PadlinkPadTests/ScanPlanTests.swift
import XCTest
@testable import PadlinkPad

/// What the pairing screen does about the camera.
///
/// `AVCaptureSession` cannot be tested: there is no way to hand it a frame. So
/// every decision it would otherwise make is pulled out to here, where the
/// three inputs are three plain values.
final class ScanPlanTests: XCTestCase {

    // MARK: - No camera at all

    /// The simulator has no camera. `AVCaptureDevice.default` returns nil and
    /// `AVCaptureDeviceInput(device:)` throws, and this is the state the whole
    /// of development happens in, so it has to be an ordinary answer rather
    /// than an error.
    func testNoCameraHardwareIsItsOwnCalmState() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: false, permission: .notDetermined, userAskedToScan: false),
            .noCamera
        )
    }

    /// Hardware is checked before permission, in both directions.
    ///
    /// Asking a device with no camera for camera permission is a prompt about
    /// something that cannot happen, and starting a session on it throws. On a
    /// simulator the authorization status can read as anything at all, so
    /// letting it decide first is what turns "no camera" into a crash.
    func testNoCameraWinsOverAGrantedPermission() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: false, permission: .granted, userAskedToScan: true),
            .noCamera
        )
    }

    func testNoCameraWinsOverADeniedPermission() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: false, permission: .denied, userAskedToScan: true),
            .noCamera
        )
    }

    // MARK: - Explaining before asking

    /// iOS asks the camera question once. Before it does, the app says what the
    /// camera is for, and waits for the user to ask for it.
    func testAnUnaskedPermissionExplainsItselfFirst() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: true, permission: .notDetermined, userAskedToScan: false),
            .explain
        )
    }

    func testTheSystemPromptOnlyComesAfterTheUserAsks() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: true, permission: .notDetermined, userAskedToScan: true),
            .requestPermission
        )
    }

    // MARK: - Afterwards

    /// Already granted, so the explanation has been read and agreed to once.
    /// Making the user tap through it again on every visit is friction for
    /// nothing.
    func testAnAlreadyGrantedCameraStartsWithoutAskingAgain() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: true, permission: .granted, userAskedToScan: false),
            .start
        )
    }

    /// A denial is permanent until Settings changes it, so re-asking is
    /// impossible and pretending otherwise wastes the user's time.
    func testADeniedCameraNeverAsksAgain() {
        XCTAssertEqual(
            ScanPlan.step(hasCamera: true, permission: .denied, userAskedToScan: false),
            .denied
        )
        XCTAssertEqual(
            ScanPlan.step(hasCamera: true, permission: .denied, userAskedToScan: true),
            .denied
        )
    }

    // MARK: - The one state that runs a session

    /// Everything else must leave the session stopped. A session left running
    /// behind an explanation panel is a camera light on for no reason, and on a
    /// device with no camera it is a throw.
    func testOnlyOneStepEverRunsTheSession() {
        let steps: [ScanStep] = [.noCamera, .explain, .requestPermission, .start, .denied]
        XCTAssertEqual(steps.filter(\.isRunningSession), [.start])
    }
}
