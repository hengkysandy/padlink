// Padlink/PadlinkPad/ScanPlan.swift
import Foundation

/// What the app knows about camera permission.
///
/// A copy of the three answers that matter from `AVAuthorizationStatus`, so
/// that the decisions made from it can be tested. `restricted` folds into
/// `denied`: a device under parental controls or an MDM profile has no camera
/// available to Padlink and no way for the user to change that from here, which
/// is the same situation as a refusal.
enum CameraPermission: Equatable {
    case notDetermined
    case denied
    case granted
}

/// What the pairing screen should be doing about the camera right now.
enum ScanStep: Equatable {
    /// There is no camera. The simulator, always.
    case noCamera
    /// Say what the camera is for, and wait to be asked.
    case explain
    /// The user asked. Let iOS put its prompt up.
    case requestPermission
    /// Run the session.
    case start
    /// Refused. Only Settings can undo it.
    case denied

    /// The one step that has a capture session running. Everything else leaves
    /// it stopped, which is what keeps the camera indicator off while the user
    /// is reading an explanation, and what keeps a device with no camera from
    /// ever reaching `AVCaptureDeviceInput(device:)`.
    var isRunningSession: Bool {
        self == .start
    }
}

/// The camera decision, with no `AVFoundation` in it.
enum ScanPlan {
    static func step(
        hasCamera: Bool,
        permission: CameraPermission,
        userAskedToScan: Bool
    ) -> ScanStep {
        // Hardware first, before permission, in every direction.
        //
        // On a simulator there is no capture device at all:
        // `AVCaptureDevice.default(for:)` returns nil and
        // `AVCaptureDeviceInput(device:)` throws. The authorization status is
        // a separate thing and can read as anything, including granted, so a
        // switch that looks at permission first will happily walk into
        // starting a session that cannot exist. That is the whole of the
        // development experience for this app, so it is the first line here.
        guard hasCamera else { return .noCamera }

        switch permission {
        case .denied:
            return .denied
        case .granted:
            // The explanation was read and agreed to once already. Asking the
            // user to tap through it again on every visit buys nothing.
            return .start
        case .notDetermined:
            return userAskedToScan ? .requestPermission : .explain
        }
    }
}
