import Testing
@testable import ClaudeUsageCore

@Suite struct RingGeometryTests {
    @Test func sweepFractionClampsToZeroAndOne() {
        #expect(RingGeometry.sweepFraction(utilization: 0) == 0)
        #expect(RingGeometry.sweepFraction(utilization: 50) == 0.5)
        #expect(RingGeometry.sweepFraction(utilization: 100) == 1.0)
        #expect(RingGeometry.sweepFraction(utilization: 137) == 1.0)   // over 100% clamps full
        #expect(RingGeometry.sweepFraction(utilization: -5) == 0)      // negative clamps empty
    }

    // Covers R2: quarter utilization is a quarter sweep.
    @Test func sweepDegreesScalesWithUtilization() {
        #expect(RingGeometry.sweepDegrees(utilization: 25) == 90)
        #expect(RingGeometry.sweepDegrees(utilization: 100) == 360)
        #expect(RingGeometry.sweepDegrees(utilization: 0) == 0)
    }

    @Test func ringColorIsBlueBelowWarningThreshold() {
        #expect(RingGeometry.ringColor(utilization: 0) == .ring)
        #expect(RingGeometry.ringColor(utilization: 40) == .ring)
        #expect(RingGeometry.ringColor(utilization: 74.9) == .ring)
    }

    @Test func ringColorIsOrangeFromWarningThreshold() {
        #expect(RingGeometry.ringColor(utilization: 75) == .warning)
        #expect(RingGeometry.ringColor(utilization: 89.9) == .warning)
    }

    @Test func ringColorIsRedFromCriticalThreshold() {
        #expect(RingGeometry.ringColor(utilization: 90) == .critical)
        #expect(RingGeometry.ringColor(utilization: 95) == .critical)
        #expect(RingGeometry.ringColor(utilization: 100) == .critical)
    }
}
