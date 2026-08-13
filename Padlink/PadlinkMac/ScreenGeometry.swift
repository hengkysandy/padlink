// Padlink/PadlinkMac/ScreenGeometry.swift
import AppKit
import CoreGraphics

/// Screen layout in `CGEvent` coordinates, and cursor clamping.
///
/// `NSScreen.frame` uses a bottom-left origin. `CGEvent` cursor locations use
/// a top-left origin. Mixing them flips the cursor vertically, and on a single
/// screen the result looks almost plausible, so the conversion is explicit and
/// tested rather than done inline.
struct ScreenGeometry: Sendable {
    /// Screen frames in top-left (`CGEvent`) coordinates.
    let topLeftFrames: [CGRect]

    init(topLeftFrames: [CGRect]) {
        self.topLeftFrames = topLeftFrames
    }

    /// Reads the current layout from AppKit. Not covered by tests, because it
    /// depends on the machine's real displays; the conversion it delegates to
    /// is tested.
    @MainActor
    static func current() -> ScreenGeometry {
        let screens = NSScreen.screens
        guard let primaryHeight = screens.first?.frame.height else {
            return ScreenGeometry(topLeftFrames: [])
        }
        return ScreenGeometry(
            topLeftFrames: topLeftFrames(
                fromBottomLeft: screens.map(\.frame),
                primaryHeight: primaryHeight
            )
        )
    }

    /// Converts bottom-left (`NSScreen.frame`) rects to top-left (`CGEvent`)
    /// rects, given the primary screen's height `H`:
    /// `topLeftY = H - (bottomLeftY + height)`.
    static func topLeftFrames(
        fromBottomLeft frames: [CGRect],
        primaryHeight: CGFloat
    ) -> [CGRect] {
        frames.map { frame in
            CGRect(
                x: frame.origin.x,
                y: primaryHeight - (frame.origin.y + frame.height),
                width: frame.width,
                height: frame.height
            )
        }
    }

    /// Keeps a point on a real screen. A point already on one is returned
    /// unchanged. A point in a gap between differently sized displays snaps to
    /// the nearest screen rather than being pushed to the union's edge.
    func clamp(_ point: CGPoint) -> CGPoint {
        guard topLeftFrames.isEmpty == false else { return point }

        if topLeftFrames.contains(where: { $0.contains(point) }) {
            return point
        }

        var best = point
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for frame in topLeftFrames {
            let candidate = CGPoint(
                x: min(max(point.x, frame.minX), frame.maxX - 1),
                y: min(max(point.y, frame.minY), frame.maxY - 1)
            )
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }

        return best
    }
}
