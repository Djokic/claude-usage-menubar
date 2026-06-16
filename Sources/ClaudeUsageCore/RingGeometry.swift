import Foundation

/// A platform-agnostic RGBA color so ring colors can be defined and tested in the core
/// library without importing AppKit. The app layer converts these to `NSColor`.
public struct RGBAColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public extension RGBAColor {
    /// Default ring/bar color — blue `#2A78D6` (matches the Claude usage panel).
    static let ring = RGBAColor(0.165, 0.471, 0.839)
    /// Warning tint from the warning threshold (default 75%) — orange `#FAB219`.
    static let warning = RGBAColor(0.980, 0.698, 0.098)
    /// Critical tint from the critical threshold (default 90%) — red `#D03B3B`.
    static let critical = RGBAColor(0.816, 0.231, 0.231)
    /// Faint background track behind each ring.
    static let track = RGBAColor(0.5, 0.5, 0.5, 0.28)
}

/// Geometry and color math for the activity rings. Pure functions — the renderer only draws.
/// Progress arcs start at 12 o'clock and sweep clockwise.
public enum RingGeometry {
    /// Utilization (%) at/above which a ring or bar turns orange.
    public static let warningThreshold = 75.0
    /// Utilization (%) at/above which a ring or bar turns red.
    public static let criticalThreshold = 90.0

    /// Fraction of the ring filled, clamped to `0...1` (handles >100% utilization).
    public static func sweepFraction(utilization: Double) -> Double {
        min(max(utilization, 0), 100) / 100
    }

    /// Degrees of arc to sweep clockwise from 12 o'clock for a given utilization.
    public static func sweepDegrees(utilization: Double) -> Double {
        sweepFraction(utilization: utilization) * 360
    }

    /// Color for a given utilization: blue normally, orange from the warning threshold,
    /// red from the critical threshold. Applies to both rings and both progress bars.
    public static func ringColor(
        utilization: Double,
        warningThreshold: Double = RingGeometry.warningThreshold,
        criticalThreshold: Double = RingGeometry.criticalThreshold
    ) -> RGBAColor {
        if utilization >= criticalThreshold { return .critical }
        if utilization >= warningThreshold { return .warning }
        return .ring
    }
}
