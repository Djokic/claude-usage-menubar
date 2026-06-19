import Foundation

/// The OAuth credentials Claude Code stores in the Keychain.
public struct ClaudeCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Expiry as epoch milliseconds (matches Claude Code's stored format).
    public var expiresAt: Int

    public init(accessToken: String, refreshToken: String, expiresAt: Int) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// The Keychain secret is a JSON blob nesting the credentials under `claudeAiOauth`.
struct CredentialsEnvelope: Codable {
    var claudeAiOauth: ClaudeCredentials
}

public enum CredentialError: Error, Equatable, LocalizedError {
    case notAuthenticated
    case commandFailed(status: Int32, message: String)
    case commandTimedOut
    case decodingFailed(String)

    /// Human, actionable text shown in the UI — never a raw "CredentialError error N".
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not signed in to Claude Code. Open Claude Code, sign in, then try again."
        case let .commandFailed(status, _):
            return "Couldn't read your Claude credentials from the Keychain (security exited \(status)). Make sure Claude Code is installed and allow Keychain access if macOS prompts."
        case .commandTimedOut:
            return "Keychain access timed out. Try again, and allow access if macOS prompts."
        case .decodingFailed:
            return "Couldn't read the stored Claude credentials. Sign in to Claude Code again."
        }
    }
}

/// A point-in-time read of the stored access token and whether it is currently usable.
public struct TokenSnapshot: Equatable, Sendable {
    public let accessToken: String
    public let isExpired: Bool

    public init(accessToken: String, isExpired: Bool) {
        self.accessToken = accessToken
        self.isExpired = isExpired
    }
}

/// Read-only provider of the Claude Code access token.
///
/// The app deliberately never refreshes. Claude Code's refresh token is **single-use and
/// rotating**: refreshing it consumes the shared token and issues a new one, so an independent
/// refresh by this app would desync (and eventually log out) the Claude Code CLI. We only ever
/// read whatever token Claude Code currently maintains. See
/// `docs/plans/2026-06-19-003-fix-read-only-credentials-plan.md`.
public protocol TokenProvider: Sendable {
    /// The currently stored access token plus whether it is expired. Never refreshes or mutates.
    func currentToken() async throws -> TokenSnapshot
}

/// Reads Claude credentials from the macOS Keychain (with a credentials-file fallback).
///
/// Strictly read-only: it never refreshes the OAuth token and never writes the Keychain, so it
/// cannot consume Claude Code's rotating refresh token. An `actor` so the blocking `security`
/// subprocess (always run off the actor's executor — see `runCommand`) is serialized cleanly.
public actor CredentialStore: TokenProvider {
    public static let keychainService = "Claude Code-credentials"

    /// Treat a token within this many milliseconds of expiry as expired — the same cushion
    /// Claude Code uses before it refreshes, so we stop showing a token that's about to die.
    private static let expiryBufferMs: Double = 5 * 60 * 1000

    private let runner: CommandRunner
    private let now: @Sendable () -> Date
    private let fallbackFileURL: URL

    public init(
        runner: CommandRunner = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init,
        fallbackFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.runner = runner
        self.now = now
        self.fallbackFileURL = fallbackFileURL
    }

    // MARK: TokenProvider

    public func currentToken() async throws -> TokenSnapshot {
        let credentials = try await load()
        return TokenSnapshot(
            accessToken: credentials.accessToken,
            isExpired: isExpired(credentials, now: now())
        )
    }

    // MARK: Off-actor command execution

    /// Run the blocking `security` subprocess off the actor's executor (on a background queue)
    /// so a slow or prompt-blocked Keychain read never stalls a cooperative thread / main actor.
    private func runCommand(_ executable: String, _ arguments: [String]) async throws -> String {
        let runner = self.runner
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runner.run(executable, arguments) })
            }
        }
    }

    // MARK: Loading

    /// Read credentials from the Keychain; fall back to `~/.claude/.credentials.json` only when
    /// the Keychain read itself fails (item missing / access denied). Corrupt Keychain JSON is
    /// surfaced as `decodingFailed` rather than masked by the fallback.
    public func load() async throws -> ClaudeCredentials {
        do {
            let raw = try await runCommand(
                "/usr/bin/security",
                ["find-generic-password", "-s", Self.keychainService, "-w"]
            )
            return try decodeEnvelope(raw)
        } catch let error as CredentialError {
            if case .decodingFailed = error { throw error }
            return try fallbackCredentials()
        } catch {
            return try fallbackCredentials()
        }
    }

    /// Keychain read failed: try the credentials-file fallback, then surface "not signed in".
    private func fallbackCredentials() throws -> ClaudeCredentials {
        if let creds = try loadFromFallbackFile() { return creds }
        throw CredentialError.notAuthenticated
    }

    private nonisolated func loadFromFallbackFile() throws -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: fallbackFileURL) else { return nil }
        return try decodeEnvelope(String(data: data, encoding: .utf8) ?? "")
    }

    nonisolated func decodeEnvelope(_ raw: String) throws -> ClaudeCredentials {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw CredentialError.decodingFailed("empty credentials blob")
        }
        do {
            return try JSONDecoder().decode(CredentialsEnvelope.self, from: data).claudeAiOauth
        } catch {
            throw CredentialError.decodingFailed("\(error)")
        }
    }

    // MARK: Expiry

    nonisolated func isExpired(_ credentials: ClaudeCredentials, now: Date) -> Bool {
        let nowMs = now.timeIntervalSince1970 * 1000
        return Double(credentials.expiresAt) - Self.expiryBufferMs <= nowMs
    }
}
