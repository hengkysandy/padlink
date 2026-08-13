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

        let magnitude = (dx * dx + dy * dy).squareRoot()
        guard magnitude > 0 else { return (0, 0) }

        // A non-finite or non-positive gap means "we do not know", so fall
        // back to the smallest believable gap rather than producing infinity.
        let dt = (dtSeconds.isFinite && dtSeconds > Self.minimumDT)
            ? dtSeconds
            : Self.minimumDT

        let speed = magnitude / dt
        let gain = min(baseGain + speedGain * speed, maxGain)

        var outX = dx * gain * sensitivity
        var outY = dy * gain * sensitivity

        let outMagnitude = (outX * outX + outY * outY).squareRoot()
        if outMagnitude > maxOutputPerEvent {
            let scale = maxOutputPerEvent / outMagnitude
            outX *= scale
            outY *= scale
        }

        return (outX, outY)
    }
}
