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
        /// Showing last-known usage because the stored token is expired or absent — not a hard
        /// error. Recovers automatically on the next tick once Claude Code refreshes its token.
        case stale
        case error
    }

    @Published public private(set) var usage: ClaudeUsage?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var errorMessage: String?

    private let client: UsageFetching
    private let lastUsageStore: LastUsageStore
    private let interval: TimeInterval
    private let now: () -> Date
    private var timer: Timer?

    /// The most recent refresh task — exposed so callers (and tests) can await completion.
    public private(set) var lastRefreshTask: Task<Void, Never>?

    public var isPolling: Bool { timer != nil }

    public init(
        client: UsageFetching,
        lastUsageStore: LastUsageStore = LastUsageStore(),
        interval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.lastUsageStore = lastUsageStore
        self.interval = interval
        self.now = now
        // Show real last-known data immediately on launch, before the first live fetch returns.
        if let snapshot = lastUsageStore.load() {
            usage = snapshot.usage
            lastUpdated = snapshot.savedAt
            phase = .stale
        }
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
            // A superseded (cancelled) refresh must not overwrite newer state or persist stale data.
            if Task.isCancelled { return }
            let stamp = now()
            usage = result
            lastUpdated = stamp
            errorMessage = nil
            phase = .loaded
            // Persist off the main actor so the per-tick file write never stalls the UI; awaited
            // so the on-disk cache is consistent by the time refresh() returns.
            let store = lastUsageStore
            await Task.detached(priority: .utility) { store.save(result, at: stamp) }.value
        } catch {
            if Self.isStale(error) {
                // Token expired (and no usable refresh) / not signed in: not a hard error. Keep
                // showing last-known usage; it recovers once a fresh token is available.
                errorMessage = staleMessage()
                phase = .stale
            } else {
                errorMessage = Self.describe(error)
                phase = .error
            }
        }
    }

    private func staleMessage() -> String {
        usage == nil
            ? "Open Claude Code and sign in to see your usage."
            : "Token expired — open Claude Code to refresh."
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

    /// Errors that mean "the token Claude Code maintains isn't usable right now" — shown as a
    /// soft stale state (keep last-known usage), never a hard error, and never a refresh trigger.
    nonisolated static func isStale(_ error: Error) -> Bool {
        switch error {
        case UsageError.tokenExpired, UsageError.unauthorized, CredentialError.notAuthenticated:
            return true
        default:
            return false
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let credentialError as CredentialError:
            // Every credential error carries actionable text via LocalizedError.
            return credentialError.localizedDescription
        case UsageError.tokenExpired, UsageError.unauthorized:
            return "Your Claude session expired — open Claude Code to refresh it"
        case let UsageError.http(status, _):
            return "Usage request failed (HTTP \(status))"
        case UsageError.decoding:
            return "Couldn't read the usage response"
        default:
            return (error as NSError).localizedDescription
        }
    }
}
