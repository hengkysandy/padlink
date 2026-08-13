import Foundation
import Testing
@testable import PadlinkCore

private let frame = 1.0 / 60.0

@Test func zeroInputProducesZeroOutput() {
    let out = PointerAcceleration.default.accelerate(dx: 0, dy: 0, dtSeconds: frame)
    #expect(out.dx == 0)
    #expect(out.dy == 0)
}

@Test(arguments: [
    (2.0, 3.0), (-2.0, 3.0), (2.0, -3.0), (-2.0, -3.0)
])
func signIsPreservedOnBothAxes(input: (dx: Double, dy: Double)) {
    let out = PointerAcceleration.default.accelerate(
        dx: input.dx, dy: input.dy, dtSeconds: frame
    )
    #expect(out.dx.sign == input.dx.sign)
    #expect(out.dy.sign == input.dy.sign)
}

@Test func outputGrowsWithInput() {
    let accel = PointerAcceleration.default
    let small = accel.accelerate(dx: 1, dy: 0, dtSeconds: frame)
    let medium = accel.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    let large = accel.accelerate(dx: 20, dy: 0, dtSeconds: frame)
    #expect(small.dx < medium.dx)
    #expect(medium.dx < large.dx)
}

@Test func axesBehaveIdentically() {
    let accel = PointerAcceleration.default
    let horizontal = accel.accelerate(dx: 7, dy: 0, dtSeconds: frame)
    let vertical = accel.accelerate(dx: 0, dy: 7, dtSeconds: frame)
    #expect(abs(horizontal.dx - vertical.dy) < 1e-9)
    #expect(horizontal.dy == 0)
    #expect(vertical.dx == 0)
}

@Test func fasterMovementCoversMoreDistanceForTheSameDelta() {
    let accel = PointerAcceleration.default
    let slow = accel.accelerate(dx: 10, dy: 0, dtSeconds: 0.100)
    let fast = accel.accelerate(dx: 10, dy: 0, dtSeconds: 0.004)
    #expect(fast.dx > slow.dx)
}

@Test func outputIsBoundedSoTheCursorCannotTeleport() {
    let accel = PointerAcceleration.default
    // A huge delta with an absurdly small time gap. This is what a timing
    // hiccup after the app is backgrounded looks like.
    let out = accel.accelerate(dx: 30_000, dy: 30_000, dtSeconds: 0.000_001)
    let magnitude = (out.dx * out.dx + out.dy * out.dy).squareRoot()
    #expect(magnitude <= accel.maxOutputPerEvent + 1e-9)
}

@Test(arguments: [0.0, -1.0, .infinity, .nan])
func degenerateTimeGapsNeverProduceNaNOrInfinity(dt: Double) {
    let out = PointerAcceleration.default.accelerate(dx: 5, dy: 5, dtSeconds: dt)
    #expect(out.dx.isFinite)
    #expect(out.dy.isFinite)
}

@Test func sensitivityScalesTheResult() {
    var slow = PointerAcceleration.default
    slow.sensitivity = 0.5
    var fast = PointerAcceleration.default
    fast.sensitivity = 2.0
    let a = slow.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    let b = fast.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    #expect(b.dx > a.dx)
}

// MARK: - Round 1 fixes: non-finite / extreme-magnitude dx, dy, sensitivity

@Test(arguments: [
    (Double.nan, 5.0), (5.0, Double.nan),
    (Double.infinity, 5.0), (5.0, Double.infinity),
    (-Double.infinity, 5.0), (Double.nan, Double.nan),
    (Double.infinity, Double.infinity)
])
func nonFiniteDeltaNeverProducesNaNOrInfinity(input: (dx: Double, dy: Double)) {
    let out = PointerAcceleration.default.accelerate(
        dx: input.dx, dy: input.dy, dtSeconds: frame
    )
    #expect(out.dx.isFinite)
    #expect(out.dy.isFinite)
}

@Test func extremeMagnitudeDeltaIsBoundedAndFinite() {
    let accel = PointerAcceleration.default
    let out = accel.accelerate(dx: .greatestFiniteMagnitude, dy: 0, dtSeconds: frame)
    #expect(out.dx.isFinite)
    #expect(out.dy.isFinite)
    let magnitude = (out.dx * out.dx + out.dy * out.dy).squareRoot()
    #expect(magnitude <= accel.maxOutputPerEvent + 1e-9)
}

@Test func extremeSensitivityIsBoundedAndFinite() {
    var accel = PointerAcceleration.default
    accel.sensitivity = 1e300
    let out = accel.accelerate(dx: 5, dy: 0, dtSeconds: frame)
    #expect(out.dx.isFinite)
    #expect(out.dy.isFinite)
    let magnitude = (out.dx * out.dx + out.dy * out.dy).squareRoot()
    #expect(magnitude <= accel.maxOutputPerEvent + 1e-9)
}

@Test func clampingPreservesTheInputRatio() {
    let accel = PointerAcceleration.default
    let dx = 30_000.0
    let dy = 10_000.0
    let out = accel.accelerate(dx: dx, dy: dy, dtSeconds: 0.000_001)
    // Cross-multiply instead of dividing, so a zero denominator can't hide a bug.
    #expect(abs(out.dx * dy - out.dy * dx) < 1e-6)
}
