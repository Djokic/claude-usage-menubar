import Foundation
@testable import ClaudeUsageCore

/// Records calls and returns canned output (or throws) for the `security` CLI seam.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    var handler: (String, [String], String?) throws -> String
    private(set) var calls: [(executable: String, arguments: [String], stdin: String?)] = []

    init(handler: @escaping (String, [String], String?) throws -> String = { _, _, _ in "" }) {
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String {
        calls.append((executable, arguments, stdin))
        return try handler(executable, arguments, stdin)
    }
}

/// Returns queued HTTP responses (or throws), recording the requests it received.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Stub {
        let data: Data
        let status: Int
        init(_ data: Data, _ status: Int) {
            self.data = data
            self.status = status
        }
    }

    private var stubs: [Stub]
    var errorToThrow: Error?
    /// Optional artificial latency so concurrent callers genuinely overlap in tests.
    var delay: TimeInterval = 0
    private(set) var requests: [URLRequest] = []

    init(stubs: [Stub] = [], errorToThrow: Error? = nil) {
        self.stubs = stubs
        self.errorToThrow = errorToThrow
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let errorToThrow { throw errorToThrow }
        let stub = stubs.isEmpty ? Stub(Data(), 500) : stubs.removeFirst()
        let http = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (stub.data, http)
    }
}

/// Read-only token-provider stub for the usage-client tests.
final class FakeTokenProvider: TokenProvider, @unchecked Sendable {
    var token: String
    var isExpired: Bool
    var error: Error?
    private(set) var calls = 0

    init(token: String, isExpired: Bool = false) {
        self.token = token
        self.isExpired = isExpired
    }

    func currentToken() async throws -> TokenSnapshot {
        calls += 1
        if let error { throw error }
        return TokenSnapshot(accessToken: token, isExpired: isExpired)
    }
}

/// Usage-fetching stub for the app-state tests. Counts calls and returns a settable result.
final class FakeUsageClient: UsageFetching, @unchecked Sendable {
    var result: Result<ClaudeUsage, Error>
    private(set) var callCount = 0

    init(result: Result<ClaudeUsage, Error>) {
        self.result = result
    }

    func fetchUsage() async throws -> ClaudeUsage {
        callCount += 1
        return try result.get()
    }
}

extension ClaudeUsage {
    /// Convenience sample with both required windows populated.
    static func sample(fiveHour: Double = 19, sevenDay: Double = 3) -> ClaudeUsage {
        ClaudeUsage(
            fiveHour: UsageWindow(utilization: fiveHour, resetsAt: Date(timeIntervalSince1970: 2_000_000)),
            sevenDay: UsageWindow(utilization: sevenDay, resetsAt: Date(timeIntervalSince1970: 3_000_000))
        )
    }
}

enum TestError: Error { case boom }
