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

    @Test func loadReadsFromKeychain() async throws {
        let runner = FakeCommandRunner { exe, args, _ in
            #expect(exe == "/usr/bin/security")
            #expect(args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            return self.blob(access: "from-keychain")
        }
        let store = CredentialStore(runner: runner, transport: FakeTransport())
        let creds = try await store.load()
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

    @Test func loadThrowsWhenKeychainFailsAndNoFallback() async {
        let runner = FakeCommandRunner { _, _, _ in throw TestError.boom }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: nonexistentFallback())
        await #expect(throws: CredentialError.notAuthenticated) { try await store.load() }
    }

    @Test func loadFallsBackToCredentialsFile() async throws {
        let runner = FakeCommandRunner { _, _, _ in throw TestError.boom }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        try blob(access: "from-file").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: tmp)
        let creds = try await store.load()
        #expect(creds.accessToken == "from-file")
    }

    private func futureExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) + 100 * 60 * 1000 }
    private func pastExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) - 1000 }

    @Test func validAccessTokenReturnsCurrentWhenNotExpired() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _, _ in self.blob(access: "live-token", expiresAt: self.futureExpiry(fixedNow)) }
        let transport = FakeTransport()
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let token = try await store.validAccessToken()
        #expect(token == "live-token")
        #expect(transport.requests.isEmpty)  // no refresh when the token is still valid
    }

    // Covers R4: refresh + use still happens when the token is expired.
    @Test func validAccessTokenRefreshesWhenExpired() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(access: "stale", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = """
        {"access_token":"fresh-token","refresh_token":"new-ref","expires_in":3600}
        """.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let token = try await store.validAccessToken()
        #expect(token == "fresh-token")
        #expect(transport.requests.count == 1)
    }

    // Covers R2 (path): a slow/blocking runner is awaited off the actor executor and still
    // resolves correctly. (Non-blocking of the executor is structural; this exercises the bridge.)
    @Test func validAccessTokenCompletesWithSlowRunner() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return self.blob(access: "slow-but-ok", expiresAt: self.futureExpiry(fixedNow))
        }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })
        let token = try await store.validAccessToken()
        #expect(token == "slow-but-ok")
    }

    // Covers R1: concurrent refreshes coalesce into a single OAuth POST.
    @Test func concurrentRefreshesCoalesceIntoOnePost() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password"
                ? self.blob(refresh: "old-ref", expiresAt: self.pastExpiry(fixedNow))
                : ""
        }
        let refreshJSON = """
        {"access_token":"coalesced","refresh_token":"rotated","expires_in":3600}
        """.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])  // only ONE response available
        transport.delay = 0.2  // hold the in-flight refresh so all callers join it
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let results = try await withThrowingTaskGroup(of: ClaudeCredentials.self) { group in
            for _ in 0..<10 { group.addTask { try await store.refresh() } }
            var all: [ClaudeCredentials] = []
            for try await r in group { all.append(r) }
            return all
        }

        #expect(transport.requests.count == 1)  // one rotation for all 10 callers
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0.accessToken == "coalesced" })
    }

    @Test func refreshAfterCompletionStartsNewPost() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(refresh: "r", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let json1 = #"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.data(using: .utf8)!
        let json2 = #"{"access_token":"a2","refresh_token":"r2","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(json1, 200), .init(json2, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let first = try await store.refresh()
        let second = try await store.refresh()
        #expect(first.accessToken == "a1")
        #expect(second.accessToken == "a2")  // a later refresh is a genuinely new exchange
        #expect(transport.requests.count == 2)
    }

    @Test func failedRefreshPropagatesAndAllowsRetry() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(refresh: "r", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let okJSON = #"{"access_token":"ok","refresh_token":"r2","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(Data(), 500), .init(okJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        await #expect(throws: CredentialError.self) { try await store.refresh() }
        let retried = try await store.refresh()  // in-flight task was cleared; a new one runs
        #expect(retried.accessToken == "ok")
    }
}
