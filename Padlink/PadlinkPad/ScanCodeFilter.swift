// Padlink/PadlinkPad/ScanCodeFilter.swift
import Foundation

/// Which scanned codes are worth acting on, with no `AVFoundation` in it.
///
/// `AVCaptureMetadataOutput` reports every code it can see in every frame it can
/// see it in, which is dozens a second. Without a filter, one deliberate act by
/// the user becomes dozens of parse attempts, and a code that is *not* a Padlink
/// code rewrites the error message on screen forty times a second for as long as
/// it stays in frame.
///
/// This is a plain value type on purpose. The delegate callback that feeds it
/// cannot be tested, because there is no way to hand `AVCaptureMetadataOutput` a
/// frame and no camera on the simulator to produce one. So the callback decides
/// nothing and this does, which is the same split `ScanPlan` and `PairingIntake`
/// already use.
///
/// ## Why a set, and not one "last code seen"
///
/// A single slot fails whenever two codes are in frame at once: the first evicts
/// the second, the second evicts the first, and every frame re-delivers both. A
/// second QR code anywhere on the Mac's screen is enough to trigger it, and the
/// de-duplication then does nothing in exactly the situation it exists for.
///
/// The cost is that a code already delivered stays suppressed even after it
/// leaves the frame and comes back. That is the right trade: parsing a code is
/// deterministic, so re-reading it produces the identical result it produced the
/// first time. The set is bounded by the number of distinct codes the camera
/// sees during one visit to the pairing screen, and `reset()` empties it.
struct ScanCodeFilter {
    /// Every code handed upward since the last `suspend()`.
    private var delivered: Set<String> = []

    /// Whether the session is meant to be running.
    ///
    /// True to begin with. Nothing can reach `accept` before the session starts,
    /// because the metadata delegate is only attached inside `configure()`.
    private var isAccepting = true

    /// Returns the codes from this frame that have not been delivered yet, in
    /// the order the frame reported them.
    mutating func accept(_ codes: [String]) -> [String] {
        // Dropped without being recorded, so restarting the session can still
        // read the code the camera is looking at right now.
        guard isAccepting else { return [] }

        var fresh: [String] = []
        for code in codes where delivered.contains(code) == false {
            // Inserted as we go, not in a second pass, so one frame that reports
            // the same code twice still delivers it once.
            delivered.insert(code)
            fresh.append(code)
        }
        return fresh
    }

    /// The session was told to stop. Forget everything, and deliver nothing
    /// until it is told to start again.
    ///
    /// Both halves matter. Forgetting is what lets a user who backs out of
    /// pairing and comes back read the same code again; without it the camera is
    /// pointed at a code the app has decided to ignore and the screen never
    /// responds. Refusing to deliver is what handles the frames that are still
    /// in flight: `stopRunning()` happens on the camera queue while callbacks
    /// arrive on the main queue, so a frame captured before the stop can be
    /// delivered after it. Acting on one of those calls `submitPairing` for a
    /// screen the user has already left.
    mutating func suspend() {
        isAccepting = false
        delivered.removeAll()
    }

    /// The session is running again.
    mutating func resume() {
        isAccepting = true
    }
}
