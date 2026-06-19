import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct UsageClientTests {
    private static let sampleJSON = """
    {"five_hour":{"utilization":19,"resets_at":"2026-06-16T18:45:00Z"},
     "seven_day":{"utilization":3,"resets_at":"2026-06-23T13:00:00Z"}}
    """.data(using: .utf8)!

    // Request shape and headers.
    @Test func sendsGetWithExactHeaders() async throws {
        let transport = FakeTransport(stubs: [.init(Self.sampleJSON, 200)])
        let client = UsageClient(
            tokenProvider: FakeTokenProvider(token: "tok-123"),
            transport: transport,
            userAgent: "claude-code/2.0.67"
        )
        _ = try await client.fetchUsage()

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer tok-123")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "user-agent") == "claude-code/2.0.67")
    }

    @Test func decodesSuccessfulResponse() async throws {
        let transport = FakeTransport(stubs: [.init(Self.sampleJSON, 200)])
        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "t"), transport: transport)
        let usage = try await client.fetchUsage()
        #expect(usage.fiveHour?.utilization == 19)
        #expect(usage.sevenDay?.utilization == 3)
    }

    // Expired stored token: throws tokenExpired WITHOUT hitting the API (no refresh exists).
    @Test func expiredTokenThrowsWithoutHittingApi() async throws {
        let transport = FakeTransport(stubs: [.init(Self.sampleJSON, 200)])
        let provider = FakeTokenProvider(token: "stale", isExpired: true)
        let client = UsageClient(tokenProvider: provider, transport: transport)

        await #expect(throws: UsageError.tokenExpired) { try await client.fetchUsage() }
        #expect(transport.requests.isEmpty)  // never called the server with a dead token
        #expect(provider.calls == 1)
    }

    // A 401 on a non-expired token throws unauthorized WITHOUT retry/refresh (single request).
    @Test func unauthorizedOnSingle401WithNoRetry() async throws {
        let transport = FakeTransport(stubs: [.init(Data(), 401)])
        let provider = FakeTokenProvider(token: "valid")
        let client = UsageClient(tokenProvider: provider, transport: transport)

        await #expect(throws: UsageError.unauthorized) { try await client.fetchUsage() }
        #expect(transport.requests.count == 1)  // no second attempt
        #expect(provider.calls == 1)            // token read once, never re-fetched/refreshed
    }

    @Test func throwsHttpErrorOnServerFailure() async throws {
        let transport = FakeTransport(stubs: [.init("boom".data(using: .utf8)!, 500)])
        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "t"), transport: transport)

        await #expect(throws: UsageError.http(status: 500, body: "boom")) {
            try await client.fetchUsage()
        }
    }

    @Test func propagatesTransportError() async throws {
        let transport = FakeTransport(errorToThrow: TestError.boom)
        let client = UsageClient(tokenProvider: FakeTokenProvider(token: "t"), transport: transport)

        await #expect(throws: (any Error).self) {
            try await client.fetchUsage()
        }
    }
}
