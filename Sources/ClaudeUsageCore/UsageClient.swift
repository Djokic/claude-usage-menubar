import Foundation

public enum UsageError: Error, Equatable {
    /// The stored access token is expired and no refreshed token is available (read-only machine,
    /// or a refresh attempt failed), so there's nothing valid to send. Resolves on its own once
    /// Claude Code refreshes its token.
    case tokenExpired
    /// The server rejected the (non-expired) token with a 401. Not retried — refreshing would
    /// consume Claude Code's single-use rotating refresh token.
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
}

/// Fetches usage. Abstracted so `AppState` can be tested with a stub.
public protocol UsageFetching: Sendable {
    func fetchUsage() async throws -> ClaudeUsage
}

/// Queries `GET https://api.anthropic.com/api/oauth/usage` with the OAuth headers the Claude Code
/// CLI uses. It sends only a non-expired token: the `TokenProvider` may have refreshed it (on
/// machines where that's safe) or returned it expired (read-only machines). An expired token is
/// surfaced as `.tokenExpired` without any request; a 401 is surfaced without retry — the client
/// itself never triggers a refresh.
public final class UsageClient: UsageFetching, @unchecked Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let tokenProvider: TokenProvider
    private let transport: HTTPTransport
    private let userAgent: String

    public init(
        tokenProvider: TokenProvider,
        transport: HTTPTransport = URLSessionTransport(),
        userAgent: String = AppInfo.userAgent
    ) {
        self.tokenProvider = tokenProvider
        self.transport = transport
        self.userAgent = userAgent
    }

    public func fetchUsage() async throws -> ClaudeUsage {
        let snapshot = try await tokenProvider.currentToken()
        // Don't even hit the API with a known-expired token — there's no refresh to fall back on,
        // and a dead token presents nothing useful. Surface it as stale and wait for Claude Code.
        guard !snapshot.isExpired else { throw UsageError.tokenExpired }

        let (data, response) = try await transport.send(makeRequest(token: snapshot.accessToken))

        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw UsageError.unauthorized }
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw UsageError.http(status: response.statusCode, body: body)
        }

        do {
            return try ClaudeUsage.decode(from: data)
        } catch {
            throw UsageError.decoding("\(error)")
        }
    }

    private func makeRequest(token: String) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        // Cap below the 60s poll interval so a hung connection can't occupy a poll slot until the
        // next tick fires on top of it.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        return request
    }
}
