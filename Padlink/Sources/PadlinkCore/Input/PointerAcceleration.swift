import Foundation

/// Turns a raw finger delta into a cursor delta.
///
/// This runs on the Mac, not the iPad, because only the Mac knows its screen
/// geometry. The iPad supplies the delta and its own measured time gap.
public struct PointerAcceleration: Sendable, Equatable {
    /// User-facing multiplier. 1.0 is neutral.
    public var sensitivity: Double
    /// Gain applied even when the finger is barely moving.
    public var baseGain: Double
    /// Extra gain per point-per-second of finger speed.
    public var speedGain: Double
    /// Ceiling on gain, so very fast flicks stay controllable.
    public var maxGain: Double
    /// Hard ceiling on the distance one event may move the cursor.
    /// This is what stops a timing hiccup teleporting the cursor.
    public var maxOutputPerEvent: Double

    public init(
        sensitivity: Double = 1.0,
        baseGain: Double = 1.0,
        speedGain: Double = 0.0018,
        maxGain: Double = 6.0,
        maxOutputPerEvent: Double = 400
    ) {
        self.sensitivity = sensitivity
        self.baseGain = baseGain
        self.speedGain = speedGain
        self.maxGain = maxGain
        self.maxOutputPerEvent = maxOutputPerEvent
    }

    public static let `default` = PointerAcceleration()

    /// Smallest time gap we will believe. Anything smaller is a measurement
    /// artefact, and dividing by it would produce an enormous speed.
    private static let minimumDT = 0.001

    public func accelerate(
        dx: Double,
        dy: Double,
        dtSeconds: Double
    ) -> (dx: Double, dy: Double) {
        guard dx.isFinite, dy.isFinite else { return (0, 0) }

        // `hypot` avoids the overflow that `(dx * dx + dy * dy).squareRoot()`
        // hits once `dx` or `dy` gets close to `Double.greatestFiniteMagnitude`.
        let magnitude = Foundation.hypot(dx, dy)
        guard magnitude > 0 else { return (0, 0) }

        // A non-finite or non-positive gap means "we do not know", so fall
        // back to the smallest believable gap rather than producing infinity.
        let dt = (dtSeconds.isFinite && dtSeconds > Self.minimumDT)
            ? dtSeconds
            : Self.minimumDT

        let speed = magnitude / dt
        let gain = min(baseGain + speedGain * speed, maxGain)

        // Work in magnitude and unit-direction, not raw (dx, dy). The unit
        // vector is always finite and within [-1, 1], even when `dx`/`dy`
        // are near `Double.greatestFiniteMagnitude`, so scaling it by a
        // bounded output magnitude can never itself overflow.
        let unitX = dx / magnitude
        let unitY = dy / magnitude

        // `magnitude * gain * sensitivity` can still overflow to infinity,
        // for example with an extreme sensitivity. Treat that as "clearly
        // over the cap" rather than dividing infinity by infinity, which is
        // where the old implementation produced NaN.
        let rawOutputMagnitude = magnitude * gain * sensitivity
        let outputMagnitude = rawOutputMagnitude.isFinite
            ? min(rawOutputMagnitude, maxOutputPerEvent)
            : maxOutputPerEvent

        return (unitX * outputMagnitude, unitY * outputMagnitude)
    }
}
