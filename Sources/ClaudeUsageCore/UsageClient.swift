import Foundation

public enum UsageError: Error, Equatable {
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
}

/// Fetches usage. Abstracted so `AppState` can be tested with a stub.
public protocol UsageFetching: Sendable {
    func fetchUsage() async throws -> ClaudeUsage
}

/// Queries `GET https://api.anthropic.com/api/oauth/usage` with the OAuth headers the
/// Claude Code CLI uses, retrying once with a refreshed token on a 401.
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
        let token = try await tokenProvider.validAccessToken()
        var (data, response) = try await transport.send(makeRequest(token: token))

        if response.statusCode == 401 {
            let refreshed = try await tokenProvider.forceRefreshAccessToken()
            (data, response) = try await transport.send(makeRequest(token: refreshed))
        }

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
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        return request
    }
}
