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

public enum CredentialError: Error, Equatable {
    case notAuthenticated
    case commandFailed(status: Int32, message: String)
    case refreshFailed(status: Int, message: String)
    case decodingFailed(String)
}

/// Abstraction so the usage client can obtain a usable access token (refreshing if needed)
/// without depending on the concrete Keychain-backed store.
public protocol TokenProvider: Sendable {
    /// A non-expired access token, refreshing transparently if the cached one is near expiry.
    func validAccessToken() async throws -> String
    /// Force a refresh and return the new access token (used after a 401).
    func forceRefreshAccessToken() async throws -> String
}

/// Loads Claude credentials from the macOS Keychain (with a credentials-file fallback),
/// refreshes the OAuth token when near expiry, and persists rotated tokens back.
public final class CredentialStore: TokenProvider, @unchecked Sendable {
    public static let keychainService = "Claude Code-credentials"
    public static let keychainAccount = "claude-cli"

    private static let refreshURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let scope = "user:profile user:inference user:sessions:claude_code"
    /// Refresh once we're within this many milliseconds of expiry.
    private static let expiryBufferMs: Double = 5 * 60 * 1000

    private let runner: CommandRunner
    private let transport: HTTPTransport
    private let now: () -> Date
    private let fallbackFileURL: URL

    public init(
        runner: CommandRunner = ProcessCommandRunner(),
        transport: HTTPTransport = URLSessionTransport(),
        now: @escaping () -> Date = Date.init,
        fallbackFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    ) {
        self.runner = runner
        self.transport = transport
        self.now = now
        self.fallbackFileURL = fallbackFileURL
    }

    // MARK: Loading

    /// Read credentials from the Keychain; fall back to `~/.claude/.credentials.json`
    /// only when the Keychain read itself fails (item missing / access denied).
    public func load() throws -> ClaudeCredentials {
        do {
            let raw = try runner.run(
                "/usr/bin/security",
                ["find-generic-password", "-s", Self.keychainService, "-w"]
            )
            return try decodeEnvelope(raw)
        } catch let error as CredentialError {
            // Decoding errors are real corruption — don't mask them with the fallback.
            if case .decodingFailed = error { throw error }
            if let creds = try loadFromFallbackFile() { return creds }
            throw CredentialError.notAuthenticated
        } catch {
            if let creds = try loadFromFallbackFile() { return creds }
            throw CredentialError.notAuthenticated
        }
    }

    private func loadFromFallbackFile() throws -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: fallbackFileURL) else { return nil }
        return try decodeEnvelope(String(data: data, encoding: .utf8) ?? "")
    }

    func decodeEnvelope(_ raw: String) throws -> ClaudeCredentials {
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

    func isExpired(_ credentials: ClaudeCredentials, now: Date) -> Bool {
        let nowMs = now.timeIntervalSince1970 * 1000
        return Double(credentials.expiresAt) - Self.expiryBufferMs <= nowMs
    }

    // MARK: Refresh

    /// Refresh the OAuth token and persist the (rotated) credentials back to the Keychain.
    /// Re-reads current credentials first so tokens Claude Code already rotated are used.
    @discardableResult
    public func refresh() async throws -> ClaudeCredentials {
        let current = try load()

        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
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

        let newCredentials = ClaudeCredentials(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            expiresAt: Int(now().timeIntervalSince1970 * 1000) + parsed.expiresIn * 1000
        )
        try persist(newCredentials)
        return newCredentials
    }

    /// Write credentials to the Keychain. Passing the JSON as a single process argument
    /// (no shell) means no quote-escaping is needed and special characters survive intact.
    func persist(_ credentials: ClaudeCredentials) throws {
        let envelope = CredentialsEnvelope(claudeAiOauth: credentials)
        let data = try JSONEncoder().encode(envelope)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        _ = try runner.run("/usr/bin/security", [
            "add-generic-password", "-U",
            "-a", Self.keychainAccount,
            "-s", Self.keychainService,
            "-w", json,
        ])
    }

    // MARK: TokenProvider

    public func validAccessToken() async throws -> String {
        let credentials = try load()
        if isExpired(credentials, now: now()) {
            return try await refresh().accessToken
        }
        return credentials.accessToken
    }

    public func forceRefreshAccessToken() async throws -> String {
        try await refresh().accessToken
    }
}

/// OAuth token-refresh response.
struct RefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
