import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite struct CredentialsTests {
    private func blob(access: String = "acc", refresh: String = "ref", expiresAt: Int = 0) -> String {
        """
        {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"\(refresh)","expiresAt":\(expiresAt)}}
        """
    }

    private func nonexistentFallback() -> URL {
        URL(fileURLWithPath: "/tmp/claude-usage-tests-does-not-exist-\(UUID().uuidString).json")
    }

    @Test func decodesKeychainBlob() throws {
        let store = CredentialStore(runner: FakeCommandRunner(), transport: FakeTransport())
        let creds = try store.decodeEnvelope(blob(access: "tok-a", refresh: "tok-r", expiresAt: 12345))
        #expect(creds.accessToken == "tok-a")
        #expect(creds.refreshToken == "tok-r")
        #expect(creds.expiresAt == 12345)
    }

    @Test func loadReadsFromKeychain() throws {
        let runner = FakeCommandRunner { exe, args, _ in
            #expect(exe == "/usr/bin/security")
            #expect(args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            return self.blob(access: "from-keychain")
        }
        let store = CredentialStore(runner: runner, transport: FakeTransport())
        let creds = try store.load()
        #expect(creds.accessToken == "from-keychain")
    }

    @Test func isExpiredHonorsFiveMinuteBuffer() {
        let store = CredentialStore(runner: FakeCommandRunner(), transport: FakeTransport())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        let valid = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 10 * 60 * 1000)
        let nearExpiry = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 2 * 60 * 1000)
        let past = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs - 1000)

        #expect(store.isExpired(valid, now: now) == false)
        #expect(store.isExpired(nearExpiry, now: now) == true)  // within 5-min buffer
        #expect(store.isExpired(past, now: now) == true)
    }

    // Covers R6: refresh posts the correct OAuth body.
    @Test func refreshBuildsCorrectPostBody() async throws {
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(refresh: "old-refresh") : ""
        }
        let refreshJSON = """
        {"access_token":"new-acc","refresh_token":"new-ref","expires_in":3600}
        """.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])

        let store = CredentialStore(runner: runner, transport: transport)
        _ = try await store.refresh()

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://console.anthropic.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "old-refresh")
        #expect(json["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(json["scope"] == "user:profile user:inference user:sessions:claude_code")
    }

    @Test func refreshComputesExpiryAndPersistsRotatedToken() async throws {
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(refresh: "old-refresh") : ""
        }
        let refreshJSON = """
        {"access_token":"new-acc","refresh_token":"rotated-ref","expires_in":3600}
        """.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let fixedNow = Date(timeIntervalSince1970: 2_000_000)

        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })
        let creds = try await store.refresh()

        #expect(creds.accessToken == "new-acc")
        #expect(creds.refreshToken == "rotated-ref")
        #expect(creds.expiresAt == Int(fixedNow.timeIntervalSince1970 * 1000) + 3600 * 1000)

        // Persist invoked with the update flag, account, service, and rotated token.
        let persist = try #require(runner.lastPersistArguments)
        #expect(persist.contains("-U"))
        #expect(persist.contains("claude-cli"))
        #expect(persist.contains("Claude Code-credentials"))
        let persistedJSON = try #require(persist.last)
        #expect(persistedJSON.contains("rotated-ref"))
    }

    @Test func loadThrowsWhenKeychainFailsAndNoFallback() {
        let runner = FakeCommandRunner { _, _, _ in throw TestError.boom }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: nonexistentFallback())
        #expect(throws: CredentialError.notAuthenticated) { try store.load() }
    }

    @Test func loadFallsBackToCredentialsFile() throws {
        let runner = FakeCommandRunner { _, _, _ in throw TestError.boom }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        try blob(access: "from-file").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: tmp)
        let creds = try store.load()
        #expect(creds.accessToken == "from-file")
    }

    @Test func persistPassesSpecialCharactersThroughIntact() throws {
        let runner = FakeCommandRunner()
        let store = CredentialStore(runner: runner, transport: FakeTransport())
        let tricky = ClaudeCredentials(
            accessToken: "a'b\"c\\d",
            refreshToken: "x'y\"z",
            expiresAt: 999
        )
        try store.persist(tricky)

        // No shell escaping: the JSON arrives verbatim as a single argument and round-trips.
        let persistedJSON = try #require(runner.lastPersistArguments?.last)
        let data = try #require(persistedJSON.data(using: .utf8))
        let roundTripped = try store.decodeEnvelope(String(data: data, encoding: .utf8)!)
        #expect(roundTripped == tricky)
    }
}
