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
    case refreshFailed(status: Int, message: String)
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
        case let .refreshFailed(status, _):
            return "Couldn't refresh your Claude session (HTTP \(status)). Open Claude Code to refresh it."
        case .decodingFailed:
            return "Couldn't read the stored Claude credentials. Sign in to Claude Code again."
        }
    }
}

/// A point-in-time read of the access token and whether it is currently usable.
public struct TokenSnapshot: Equatable, Sendable {
    public let accessToken: String
    public let isExpired: Bool

    public init(accessToken: String, isExpired: Bool) {
        self.accessToken = accessToken
        self.isExpired = isExpired
    }
}

/// Provides a usable Claude Code access token.
///
/// Refreshing consumes Claude Code's single-use, rotating refresh token, so it is done ONLY when
/// the rotated token can be written back to the Keychain (proven by the first-launch write-access
/// probe) — otherwise Claude Code would be left holding a dead token and logged out. When refresh
/// isn't available, `currentToken()` returns the stored token with `isExpired` set, and callers
/// must not send an expired token to the API.
public protocol TokenProvider: Sendable {
    func currentToken() async throws -> TokenSnapshot
}

/// Reads Claude credentials from the macOS Keychain (with a credentials-file fallback) and, on
/// machines where the Keychain write-back is permitted, refreshes the OAuth token near expiry and
/// writes the rotated token back so the Claude Code CLI stays in sync. Where the write is denied,
/// it never refreshes and never consumes the shared token (read-only).
///
/// An `actor` so the single-flight refresh state is serialized and the blocking `security`
/// subprocess is always run off the actor's executor (see `runCommand`).
public actor CredentialStore: TokenProvider {
    public static let keychainService = "Claude Code-credentials"
    public static let keychainAccount = "claude-cli"

    private static let refreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scope = "user:profile user:inference user:sessions:claude_code"
    /// Refresh once we're within this many milliseconds of expiry.
    private static let expiryBufferMs: Double = 5 * 60 * 1000

    private let runner: CommandRunner
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private let fallbackFileURL: URL
    private let writeAccessStore: WriteAccessStore

    /// Resolved write-access capability for this session (nil until first resolved/probed).
    private var canWrite: Bool?
    private var inFlightRefresh: Task<ClaudeCredentials, Error>?
    private var probeTask: Task<Void, Never>?

    public init(
        runner: CommandRunner = ProcessCommandRunner(),
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        fallbackFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json"),
        writeAccessStore: WriteAccessStore = WriteAccessStore()
    ) {
        self.runner = runner
        self.transport = transport
        self.now = now
        self.fallbackFileURL = fallbackFileURL
        self.writeAccessStore = writeAccessStore
    }

    // MARK: TokenProvider

    public func currentToken() async throws -> TokenSnapshot {
        let credentials = try await load()
        if !isExpired(credentials, now: now()) {
            return TokenSnapshot(accessToken: credentials.accessToken, isExpired: false)
        }
        // Expired. Only refresh if we can write the rotated token back — otherwise we'd consume
        // Claude Code's single-use token without saving the replacement and log it out.
        guard writeGranted() else {
            return TokenSnapshot(accessToken: credentials.accessToken, isExpired: true)
        }
        do {
            let refreshed = try await refresh()
            // Trust a just-minted token (don't re-check expiry — avoids a refresh loop if the
            // server's expires_in is small or clocks skew within the 5-minute buffer).
            return TokenSnapshot(accessToken: refreshed.accessToken, isExpired: false)
        } catch {
            // Refresh failed — fall back to the current token, marked expired so the caller shows
            // stale and does NOT query the API. Never hard-error.
            return TokenSnapshot(accessToken: credentials.accessToken, isExpired: true)
        }
    }

    // MARK: Write-access probe

    /// Probe (once) whether this machine grants Keychain write access, surfacing the macOS modify
    /// prompt on first launch. The result is persisted so the prompt never reappears. Single-flight
    /// so concurrent callers can't trigger two prompts.
    public func ensureWriteAccessProbed() async {
        if let granted = writeAccessStore.granted {
            setWriteGranted(granted)
            return
        }
        if let probeTask {
            await probeTask.value
            return
        }
        let task = Task { () async -> Void in
            defer { self.probeTask = nil }
            self.setWriteGranted(await self.probeWriteAccess())
        }
        probeTask = task
        await task.value
    }

    /// Set the write-access capability in lockstep across the in-actor cache and the persisted flag
    /// so the two can never diverge.
    private func setWriteGranted(_ granted: Bool) {
        canWrite = granted
        writeAccessStore.granted = granted
    }

    /// Re-save the exact stored credential bytes back to the Keychain — a true no-op that only
    /// triggers the modify-ACL prompt. Returns whether the write succeeded.
    private func probeWriteAccess() async -> Bool {
        do {
            let raw = try await readRawKeychain()
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            try await persistRaw(value)
            return true
        } catch {
            return false
        }
    }

    private func writeGranted() -> Bool {
        if let canWrite { return canWrite }
        let granted = writeAccessStore.granted ?? false  // default read-only until probed
        canWrite = granted
        return granted
    }

    // MARK: Off-actor command execution

    /// Run the blocking `security` subprocess off the actor's executor (on a background queue)
    /// so a slow or prompt-blocked Keychain call never stalls a cooperative thread / main actor.
    private func runCommand(_ executable: String, _ arguments: [String], stdin: String? = nil) async throws -> String {
        let runner = self.runner
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runner.run(executable, arguments, stdin: stdin) })
            }
        }
    }

    // MARK: Loading

    private func readRawKeychain() async throws -> String {
        try await runCommand("/usr/bin/security", ["find-generic-password", "-s", Self.keychainService, "-w"])
    }

    /// Read credentials from the Keychain; fall back to `~/.claude/.credentials.json` only when
    /// the Keychain read itself fails. Corrupt Keychain JSON is surfaced as `decodingFailed`.
    public func load() async throws -> ClaudeCredentials {
        do {
            return try decodeEnvelope(try await readRawKeychain())
        } catch let error as CredentialError {
            if case .decodingFailed = error { throw error }
            return try fallbackCredentials()
        } catch {
            return try fallbackCredentials()
        }
    }

    private func fallbackCredentials() throws -> ClaudeCredentials {
        if let creds = loadFromFallbackFile() { return creds }
        throw CredentialError.notAuthenticated
    }

    /// Best-effort secondary source: a missing OR corrupt file both degrade to `nil`.
    private nonisolated func loadFromFallbackFile() -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: fallbackFileURL) else { return nil }
        return try? decodeEnvelope(String(data: data, encoding: .utf8) ?? "")
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

    // MARK: Refresh (write-gated)

    /// Refresh the OAuth token and persist the rotated credentials. Single-flight: concurrent
    /// callers coalesce onto one in-flight refresh so the single-use refresh token is exchanged
    /// exactly once.
    @discardableResult
    public func refresh() async throws -> ClaudeCredentials {
        // Never consume the single-use rotating token unless write-back is granted. Defense in
        // depth — performRefresh also proves the write actually works before the POST.
        guard writeGranted() else {
            throw CredentialError.refreshFailed(status: 0, message: "Keychain write access not granted")
        }
        if let existing = inFlightRefresh {
            return try await existing.value
        }
        let task = Task { () async throws -> ClaudeCredentials in
            // Clear the slot when the refresh itself finishes — not in the caller's defer — so a
            // cancelled caller doesn't free the slot and let a concurrent caller start a second
            // (single-use) rotation.
            defer { self.inFlightRefresh = nil }
            return try await self.performRefresh()
        }
        inFlightRefresh = task
        return try await task.value
    }

    /// Re-reads current credentials (so a token Claude Code already rotated is used), exchanges the
    /// refresh token, and persists the rotated set. A failed write-back is non-fatal: the refreshed
    /// token is returned for in-session use and refresh is disabled (downgraded to read-only) so we
    /// stop consuming the rotating token on a machine that can't save it.
    private func performRefresh() async throws -> ClaudeCredentials {
        // Read the RAW Keychain blob (not load()'s decoded 3-field form, and not the file fallback):
        // we refresh the live Keychain item in place and must preserve every field Claude Code
        // stored (scopes, subscriptionType, …).
        let raw = (try await readRawKeychain()).trimmingCharacters(in: .whitespacesAndNewlines)
        let current = try decodeEnvelope(raw)

        // Prove we can write the Keychain THIS session BEFORE consuming the single-use token: write
        // the exact stored bytes back (a true no-op). If it fails — e.g. a stale "granted" flag on a
        // machine whose ACL has since changed — downgrade to read-only and abort WITHOUT POSTing, so
        // the rotating token is never consumed on a machine that can't save the replacement.
        do {
            try await persistRaw(raw)
        } catch {
            setWriteGranted(false)
            throw error
        }

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": current.refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scope,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw CredentialError.refreshFailed(
                status: http.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let parsed: RefreshResponse
        do {
            parsed = try JSONDecoder().decode(RefreshResponse.self, from: data)
        } catch {
            throw CredentialError.decodingFailed("\(error)")
        }

        let newExpiresAt = Int(now().timeIntervalSince1970 * 1000) + parsed.expiresIn * 1000
        // Update only the three rotating fields in place, preserving every other key Claude Code
        // stored, so the rotated write-back is a faithful update rather than a degraded rewrite.
        let updated = try mergeCredentialFields(
            into: raw,
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: newExpiresAt
        )
        // Write-back should succeed (we proved it above); if it somehow fails now, keep the
        // refreshed token for this call and stop refreshing. Log the failure only — never the
        // credentials themselves.
        do {
            try await persistRaw(updated)
        } catch {
            setWriteGranted(false)
            fputs("[ClaudeUsage] Keychain write-back failed after refresh; disabling refresh: \(error)\n", stderr)
        }
        return ClaudeCredentials(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: newExpiresAt
        )
    }

    /// Update only `accessToken`/`refreshToken`/`expiresAt` under `claudeAiOauth`, preserving every
    /// other key Claude Code stored. Round-tripping through the 3-field `ClaudeCredentials` model
    /// would silently drop fields like `scopes`/`subscriptionType` and corrupt the shared item.
    private nonisolated func mergeCredentialFields(
        into raw: String, accessToken: String, refreshToken: String, expiresAt: Int
    ) throws -> String {
        guard let data = raw.data(using: .utf8),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw CredentialError.decodingFailed("unexpected credentials shape for write-back")
        }
        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = expiresAt
        root["claudeAiOauth"] = oauth
        let out = try JSONSerialization.data(withJSONObject: root)
        return String(data: out, encoding: .utf8) ?? ""
    }

    // MARK: Writing

    /// Write a raw secret string to the Keychain item. `add-generic-password -w` with no inline
    /// value prompts for the password and a "retype" confirmation, both read from stdin — so the
    /// (single-line) value is sent twice. Keeping the `security` CLI as the accessor preserves the
    /// existing Keychain ACL versus the in-process SecItem APIs.
    private func persistRaw(_ value: String) async throws {
        let stdin = "\(value)\n\(value)\n"
        _ = try await runCommand("/usr/bin/security", [
            "add-generic-password", "-U",
            "-a", Self.keychainAccount,
            "-s", Self.keychainService,
            "-w",
        ], stdin: stdin)
    }
}

/// OAuth token-refresh response.
private struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
