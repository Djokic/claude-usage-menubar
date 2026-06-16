import SwiftUI
import ClaudeUsageCore

/// The popover content: a header with a refresh button, then a progress row for the
/// 5-hour and 7-day limits (plus any per-model windows the API returns).
struct TooltipView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            content
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Claude usage")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                refreshButton
            }
            Text(updatedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var refreshButton: some View {
        Button(action: { state.manualRefresh() }) {
            if state.phase == .loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.borderless)
        .help("Refresh now")
        .disabled(state.phase == .loading)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let usage = state.usage {
            VStack(alignment: .leading, spacing: 14) {
                LimitRow(title: "Current session", window: usage.fiveHour)
                LimitRow(title: "Weekly limit", window: usage.sevenDay)

                if let opus = usage.sevenDayOpus {
                    LimitRow(title: "Weekly · Opus", window: opus, muted: true)
                }
                if let sonnet = usage.sevenDaySonnet {
                    LimitRow(title: "Weekly · Sonnet", window: sonnet, muted: true)
                }

                if state.phase == .error {
                    Label("Couldn't refresh — showing last data", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch state.phase {
        case .loading, .idle:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading usage…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
        case .error:
            VStack(alignment: .leading, spacing: 8) {
                Label(state.errorMessage ?? "Couldn't load usage",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Try again") { state.manualRefresh() }
                    .controlSize(.small)
            }
        case .loaded:
            Text("No usage data available.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var updatedText: String {
        guard let updated = state.lastUpdated else { return "Not yet updated" }
        return "Updated \(Self.timeFormatter.string(from: updated))"
    }
}

/// One labelled limit: title, "% used", a progress bar, and the reset countdown.
private struct LimitRow: View {
    let title: String
    let window: UsageWindow?
    var muted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: muted ? .regular : .medium))
                    .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer()
                Text(percentText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressBar(fraction: fraction, color: barColor)
            Text(resetText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var fraction: Double {
        guard let window else { return 0 }
        return RingGeometry.sweepFraction(utilization: window.utilization)
    }

    private var percentText: String {
        guard let window else { return "—" }
        return "\(Int(window.utilization.rounded()))% used"
    }

    private var barColor: Color {
        guard let window else { return Color(.track) }
        return Color(RingGeometry.ringColor(utilization: window.utilization))
    }

    private var resetText: String {
        guard let window else { return "No active limit" }
        let now = Date()
        let body = ResetFormatter.countdown(resetsAt: window.resetsAt, now: now)
        if body == "now" { return "Resets now" }
        if window.resetsAt.timeIntervalSince(now) >= 24 * 3600 { return "Resets \(body)" }
        return "Resets in \(body)"
    }
}

/// A rounded progress bar matching the Claude website's pill style.
private struct ProgressBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * min(max(fraction, 0), 1), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 6)
    }
}

