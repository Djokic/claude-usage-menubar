import Foundation

/// Persists the most recent successful usage snapshot to a file the app owns, so the rings can
/// show real data immediately on launch and during stale periods (token expired / Claude Code
/// idle). This holds **only** usage percentages and reset times — never tokens or credentials —
/// so unlike the shared Keychain item the app can always write it.
public struct LastUsageStore: Sendable {
    public struct Snapshot: Codable, Equatable, Sendable {
        public let usage: ClaudeUsage
        public let savedAt: Date

        public init(usage: ClaudeUsage, savedAt: Date) {
            self.usage = usage
            self.savedAt = savedAt
        }
    }

    private let fileURL: URL

    public init(fileURL: URL = LastUsageStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ClaudeUsageMenuBar/last-usage.json")
    }

    /// Save the latest usage. Best-effort: a monitor must never crash because it couldn't cache
    /// its display data, so all failures are swallowed (no secrets are involved here).
    public func save(_ usage: ClaudeUsage, at date: Date) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(Snapshot(usage: usage, savedAt: date))
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // Non-fatal: last-usage caching is best-effort.
        }
    }

    /// The last saved usage, or `nil` if absent or unreadable (missing/corrupt file).
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
