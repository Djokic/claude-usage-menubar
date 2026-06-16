import Foundation
import Combine

/// Observable usage state shared by the menu bar icon and the popover. Owns the 60-second
/// poll timer and the manual-refresh action; updates are published on the main actor.
@MainActor
public final class AppState: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case error
    }

    @Published public private(set) var usage: ClaudeUsage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var errorMessage: String?

    private let client: UsageFetching
    private let interval: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    /// The most recent refresh task — exposed so callers (and tests) can await completion.
    public private(set) var lastRefreshTask: Task<Void, Never>?

    public var isPolling: Bool { timer != nil }

    public init(client: UsageFetching, interval: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.interval = interval
        self.now = now
    }

    /// Fetch immediately and start the repeating poll.
    public func startPolling() {
        refreshNow()
        scheduleTimer()
    }

    /// User-initiated refresh: fetch now and reset the auto-poll cadence.
    public func manualRefresh() {
        scheduleTimer()
        refreshNow()
    }

    /// Stop polling and cancel any in-flight refresh.
    public func stop() {
        timer?.invalidate()
        timer = nil
        lastRefreshTask?.cancel()
    }

    /// One poll tick. Called by the timer; also directly callable in tests.
    public func pollTick() {
        refreshNow()
    }

    /// Perform a single fetch, updating published state. Fail-soft: on error the previous
    /// `usage` is retained so the rings keep showing the last good data.
    public func refresh() async {
        phase = .loading
        do {
            let result = try await client.fetchUsage()
            usage = result
            lastUpdated = now()
            errorMessage = nil
            phase = .loaded
        } catch {
            errorMessage = Self.describe(error)
            phase = .error
        }
    }

    private func refreshNow() {
        lastRefreshTask?.cancel()
        lastRefreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollTick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CredentialError.notAuthenticated:
            return "Not signed in to Claude Code"
        case UsageError.unauthorized:
            return "Authorization failed — sign in to Claude Code again"
        case let UsageError.http(status, _):
            return "Usage request failed (HTTP \(status))"
        case UsageError.decoding:
            return "Couldn't read the usage response"
        default:
            return (error as NSError).localizedDescription
        }
    }
}
