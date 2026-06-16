import AppKit
import ClaudeUsageCore

/// Draws the two concentric Apple-Watch-style rings used as the menu bar icon.
/// Outer ring = 5-hour limit, inner ring = 7-day limit. Pure drawing — all angle and
/// color decisions come from `RingGeometry` in the core library.
enum RingIconRenderer {
    /// Render the dual-ring icon. Pass `nil` for a window with no data (draws only the track).
    ///
    /// While both limits are below the warning threshold the icon is a **template** image:
    /// macOS recolors it to match the menu bar (black in light mode, white in dark mode), like
    /// Apple's own status items. As soon as a ring reaches the warning/critical threshold the
    /// icon switches to a colored (non-template) image so the orange/red alert shows at a glance.
    static func render(fiveHour: Double?, sevenDay: Double?, size: CGFloat = 18) -> NSImage {
        let colored = isAtLeastWarning(fiveHour) || isAtLeastWarning(sevenDay)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawRings(in: rect, fiveHour: fiveHour, sevenDay: sevenDay, colored: colored)
            return true
        }
        image.isTemplate = !colored
        return image
    }

    private static func isAtLeastWarning(_ utilization: Double?) -> Bool {
        (utilization ?? 0) >= RingGeometry.warningThreshold
    }

    private static func drawRings(in rect: NSRect, fiveHour: Double?, sevenDay: Double?, colored: Bool) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let lineWidth = rect.width * 0.10
        // Extra +1pt beyond the proportional gap so the two same-colored rings read as distinct.
        let gap = rect.width * 0.055 + 1.0

        let outerRadius = rect.width / 2 - lineWidth / 2 - 0.5
        let innerRadius = outerRadius - lineWidth - gap

        // Position distinguishes the rings (outer = 5h, inner = 7d); they share the same color scale.
        drawRing(center: center, radius: outerRadius, lineWidth: lineWidth, utilization: fiveHour, colored: colored)
        drawRing(center: center, radius: innerRadius, lineWidth: lineWidth, utilization: sevenDay, colored: colored)
    }

    private static func drawRing(
        center: NSPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        utilization: Double?,
        colored: Bool
    ) {
        // Faint full-circle background track. In template mode it's a low-alpha black mask
        // (recolored by the system); in colored mode a neutral gray that reads on any menu bar.
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lineWidth
        (colored ? NSColor(white: 0.5, alpha: 0.30) : NSColor(white: 0, alpha: 0.30)).setStroke()
        track.stroke()

        guard let utilization else { return }  // no data → track only

        let sweep = RingGeometry.sweepDegrees(utilization: utilization)
        guard sweep > 0 else { return }

        // Start at 12 o'clock (90°) and sweep clockwise.
        let startAngle: CGFloat = 90
        let endAngle = startAngle - CGFloat(sweep)
        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center, radius: radius,
            startAngle: startAngle, endAngle: endAngle, clockwise: true
        )
        progress.lineWidth = lineWidth
        progress.lineCapStyle = .round
        arcColor(for: utilization, colored: colored).setStroke()
        progress.stroke()
    }

    /// Menu bar ring color: orange/red at the thresholds, otherwise monochrome — a black mask
    /// in template mode (system recolors), or neutral gray for a sub-threshold ring shown
    /// alongside a warning ring in colored mode.
    private static func arcColor(for utilization: Double, colored: Bool) -> NSColor {
        if utilization >= RingGeometry.criticalThreshold { return NSColor(.critical) }
        if utilization >= RingGeometry.warningThreshold { return NSColor(.warning) }
        return colored ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0, alpha: 1)
    }

    // MARK: Headless verification

    /// PNG data for an image (used by `--render-samples` and ad-hoc checks).
    static func png(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Render a spread of sample icons to a directory for visual inspection.
    static func writeSamples(to directory: URL) throws {
        let pairs: [(Double, Double)] = [(0, 0), (25, 10), (50, 40), (75, 60), (95, 92), (100, 100)]
        for (five, seven) in pairs {
            let image = render(fiveHour: five, sevenDay: seven, size: 36)  // 2x for clarity
            guard let data = png(for: image) else { continue }
            let url = directory.appendingPathComponent("ring-\(Int(five))-\(Int(seven)).png")
            try data.write(to: url)
        }
    }
}
