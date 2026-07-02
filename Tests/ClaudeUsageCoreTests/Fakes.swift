import Foundation
@testable import ClaudeUsageCore

/// Records calls (including stdin) and returns canned output (or throws) for the `security` CLI
/// seam. The handler stays keyed on (executable, arguments); stdin is recorded for assertions.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {
    var handler: (String, [String]) throws -> String
    private(set) var calls: [(executable: String, arguments: [String], stdin: String?)] = []

    init(handler: @escaping (String, [String]) throws -> String = { _, _ in "" }) {
        self.handler = handler
    }

    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String {
        calls.append((executable, arguments, stdin))
        return try handler(executable, arguments)
    }

    var didWriteKeychain: Bool {
        calls.contains {
            $0.arguments.first == "add-generic-password"
                || ($0.arguments == ["-i"] && $0.stdin?.hasPrefix("add-generic-password") == true)
        }
    }
}

/// Scripts the `security` CLI seam as a real single-service keychain: serves item metadata and
/// secret reads, applies `-X` hex writes from both the `-i` stdin form and the argv form, and can
/// simulate write denial or the v1 silent-truncation bug — so `CredentialStore`'s read-back
/// verification is exercised against genuinely persisted state.
final class FakeSecurityCLI: CommandRunner, @unchecked Sendable {
    private(set) var items: [(account: String, secret: String)]
    var failWrites = false
    /// Simulate the v1 bug: writes report success but store only the first N bytes.
    var truncateWritesTo: Int?
    private(set) var calls: [(executable: String, arguments: [String], stdin: String?)] = []
    private(set) var writes: [(account: String, value: String, viaArgv: Bool)] = []

    init(account: String = "stefan", secret: String? = nil) {
        items = secret.map { [(account, $0)] } ?? []
    }

    func secret(account: String) -> String? {
        items.first(where: { $0.account == account })?.secret
    }

    var didWriteKeychain: Bool { !writes.isEmpty }

    func run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String {
        calls.append((executable, arguments, stdin))
        if arguments == ["-i"], let stdin {
            guard let parsed = Self.parseInlineAdd(stdin) else {
                throw CredentialError.commandFailed(status: 1, message: "unparseable -i command")
            }
            try apply(account: parsed.account, value: parsed.value, viaArgv: false)
            return ""
        }
        if arguments.first == "add-generic-password" {
            guard let aIdx = arguments.firstIndex(of: "-a"), aIdx + 1 < arguments.count,
                  let xIdx = arguments.firstIndex(of: "-X"), xIdx + 1 < arguments.count,
                  let value = Self.decodeHex(arguments[xIdx + 1]) else {
                throw CredentialError.commandFailed(status: 1, message: "unparseable argv write")
            }
            try apply(account: arguments[aIdx + 1], value: value, viaArgv: true)
            return ""
        }
        if arguments.first == "find-generic-password" {
            let wanted = arguments.firstIndex(of: "-a").flatMap { idx in
                idx + 1 < arguments.count ? arguments[idx + 1] : nil
            }
            let found = wanted.map { w in items.first { $0.account == w } } ?? items.first
            guard let item = found else {
                throw CredentialError.commandFailed(status: 44, message: "could not be found")
            }
            if arguments.last == "-w" {
                // Like the real CLI: non-ASCII secrets print hex-encoded, no 0x prefix.
                if item.secret.allSatisfy(\.isASCII) { return item.secret + "\n" }
                return Data(item.secret.utf8).map { String(format: "%02x", $0) }.joined() + "\n"
            }
            return """
            keychain: "/fake/login.keychain-db"
            class: "genp"
            attributes:
                "acct"<blob>="\(item.account)"
                "svce"<blob>="Claude Code-credentials"
            """
        }
        throw CredentialError.commandFailed(status: 2, message: "unexpected command: \(arguments)")
    }

    private func apply(account: String, value: String, viaArgv: Bool) throws {
        if failWrites { throw CredentialError.commandFailed(status: 1, message: "denied") }
        var stored = value
        if let limit = truncateWritesTo { stored = String(stored.prefix(limit)) }
        writes.append((account, stored, viaArgv))
        if let idx = items.firstIndex(where: { $0.account == account }) {
            items[idx].secret = stored
        } else {
            items.append((account, stored))  // `-U` creates when absent — the shadow-item hazard
        }
    }

    /// Parse the exact `-i` line `persistRaw` emits: `add-generic-password -U -a "…" -s "…" -X "…"`.
    static func parseInlineAdd(_ line: String) -> (account: String, value: String)? {
        guard line.hasPrefix("add-generic-password"),
              let account = quoted(in: line, after: "-a \""),
              let hex = quoted(in: line, after: "-X \""),
              let value = decodeHex(hex) else { return nil }
        return (account, value)
    }

    private static func quoted(in line: String, after prefix: String) -> String? {
        guard let start = line.range(of: prefix)?.upperBound,
              let end = line[start...].firstIndex(of: "\"") else { return nil }
        return String(line[start..<end])
    }

    static func decodeHex(_ hex: String) -> String? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return String(data: data, encoding: .utf8)
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
