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

        // Persist invoked with the update flag, account, service; the rotated token travels
        // via stdin, never in the argument list.
        let persist = try #require(runner.lastPersistArguments)
        #expect(persist.contains("-U"))
        #expect(persist.contains("claude-cli"))
        #expect(persist.contains("Claude Code-credentials"))
        #expect(persist.last == "-w")  // trailing -w with no inline value
        #expect(!persist.contains(where: { $0.contains("rotated-ref") }))
        let stdin = try #require(runner.lastPersistStdin)
        #expect(stdin.contains("rotated-ref"))
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

    // Efficiency: a still-valid cached token short-circuits validAccessToken without a Keychain read.
    @Test func validAccessTokenFastPathSkipsKeychainWhenCacheFresh() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner { _, _, _ in self.blob(access: "fresh", expiresAt: nowMs + 60 * 60 * 1000) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })

        _ = try await store.validAccessToken()          // seeds the cache (one security read)
        let callsAfterSeed = runner.calls.count
        let token = try await store.validAccessToken()  // fast path: no further security call
        #expect(token == "fresh")
        #expect(runner.calls.count == callsAfterSeed)
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

    // Covers R3: the persisted secret travels via stdin and never appears in the argument list.
    @Test func persistFeedsSecretViaStdinNotArgs() async throws {
        let runner = FakeCommandRunner()
        let store = CredentialStore(runner: runner, transport: FakeTransport())
        let tricky = ClaudeCredentials(accessToken: "a'b\"c\\d", refreshToken: "secret-RT", expiresAt: 999)
        try await store.persist(tricky)

        let args = try #require(runner.lastPersistArguments)
        #expect(args.last == "-w")
        #expect(!args.contains(where: { $0.contains("secret-RT") }))  // token never in argv

        let stdin = try #require(runner.lastPersistStdin)
        #expect(stdin.contains("secret-RT"))
        // The secret round-trips: the first stdin line decodes back to the original credentials.
        let firstLine = try #require(stdin.split(separator: "\n").first)
        let roundTripped = try store.decodeEnvelope(String(firstLine))
        #expect(roundTripped == tricky)
    }

    // Covers R1 under cancellation: cancelling one caller mid-refresh must not let a concurrent
    // caller start a second token rotation. The slot stays occupied until the work completes.
    @Test func cancellingACallerKeepsSingleFlightIntact() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            args.first == "find-generic-password" ? self.blob(refresh: "r", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = #"{"access_token":"one","refresh_token":"r2","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])  // only ONE response
        transport.delay = 0.3
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let a = Task { try? await store.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)  // let A occupy the in-flight slot
        a.cancel()

        let result = try await store.refresh()  // B joins the still-running refresh
        #expect(result.accessToken == "one")
        #expect(transport.requests.count == 1)  // a single rotation despite the cancel
    }

    // Covers R1: a failed Keychain write-back after a successful refresh is non-fatal.
    @Test func persistFailureIsNonFatalAndReturnsRotatedCreds() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            if args.first == "find-generic-password" { return self.blob(refresh: "old", expiresAt: self.pastExpiry(fixedNow)) }
            throw CredentialError.commandFailed(status: 1, message: "denied")  // persist (add-generic-password) fails
        }
        let refreshJSON = #"{"access_token":"new-acc","refresh_token":"rotated","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        let creds = try await store.refresh()  // must NOT throw despite the persist failure
        #expect(creds.accessToken == "new-acc")
        #expect(creds.refreshToken == "rotated")
    }

    // Covers R2: after a persist-failed refresh, load() serves the rotated creds from the cache.
    @Test func loadAfterPersistFailureReturnsRotatedCredsFromCache() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            if args.first == "find-generic-password" { return self.blob(access: "stale", refresh: "old", expiresAt: self.pastExpiry(fixedNow)) }
            throw CredentialError.commandFailed(status: 1, message: "denied")
        }
        let refreshJSON = #"{"access_token":"new-acc","refresh_token":"rotated","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        _ = try await store.refresh()
        let loaded = try await store.load()   // keychain still stale; cache (newer) wins
        #expect(loaded.accessToken == "new-acc")
    }

    // Covers R2: an external rotation (newer Keychain) wins over a stale cache.
    @Test func loadPrefersKeychainWhenNewerThanCache() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner()
        runner.handler = { _, _, _ in self.blob(access: "A", expiresAt: nowMs + 1000) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })

        let first = try await store.load()
        #expect(first.accessToken == "A")          // cache seeded with A

        runner.handler = { _, _, _ in self.blob(access: "B", expiresAt: nowMs + 9999) }  // Claude Code rotated externally
        let second = try await store.load()
        #expect(second.accessToken == "B")          // newer Keychain wins over cached A
    }

    // Covers R2/R4: a transient Keychain read failure falls back to the cache.
    @Test func loadFallsBackToCacheWhenKeychainReadFails() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner()
        runner.handler = { _, _, _ in self.blob(access: "cached-A", expiresAt: nowMs + 9999) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })
        _ = try await store.load()   // seed cache

        runner.handler = { _, _, _ in throw CredentialError.commandFailed(status: 1, message: "denied") }
        let loaded = try await store.load()
        #expect(loaded.accessToken == "cached-A")
    }

    // Covers R2: a later refresh uses the cached rotated token, not the stale Keychain one.
    @Test func secondRefreshUsesCachedRotatedToken() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args, _ in
            if args.first == "find-generic-password" { return self.blob(refresh: "stale-keychain", expiresAt: self.pastExpiry(fixedNow)) }
            throw CredentialError.commandFailed(status: 1, message: "denied")  // persist always denied
        }
        let json1 = #"{"access_token":"a1","refresh_token":"rotated-1","expires_in":3600}"#.data(using: .utf8)!
        let json2 = #"{"access_token":"a2","refresh_token":"rotated-2","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(json1, 200), .init(json2, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow })

        _ = try await store.refresh()   // rotates to rotated-1; persist fails; cached
        _ = try await store.refresh()   // uses cached rotated-1, not stale-keychain

        let secondBody = try #require(transport.requests.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: secondBody) as? [String: String])
        #expect(json["refresh_token"] == "rotated-1")
    }

    // Covers R4: corrupt Keychain JSON surfaces decodingFailed when there's no cached token to fall back on.
    @Test func decodingFailedFromKeychainStillThrowsAndIsNotMasked() async throws {
        let runner = FakeCommandRunner { _, _, _ in "not json at all" }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: nonexistentFallback())
        var thrown: CredentialError?
        do { _ = try await store.load() } catch let error as CredentialError { thrown = error }
        guard case .decodingFailed = thrown else {
            Issue.record("expected decodingFailed, got \(String(describing: thrown))")
            return
        }
    }

    // Covers R2: equal expiresAt is a tie — the Keychain wins (cache only wins when strictly newer).
    @Test func cacheFreshestTieGoesToKeychain() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner()
        runner.handler = { _, _, _ in self.blob(access: "cache-A", expiresAt: nowMs + 5000) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })
        _ = try await store.load()   // seed cache with A @ +5000

        runner.handler = { _, _, _ in self.blob(access: "keychain-B", expiresAt: nowMs + 5000) }  // same expiresAt
        let loaded = try await store.load()
        #expect(loaded.accessToken == "keychain-B")
    }

    // Covers R2/R4: a non-CredentialError Keychain read failure also falls back to the cache.
    @Test func loadFallsBackToCacheOnNonCredentialError() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner()
        runner.handler = { _, _, _ in self.blob(access: "cached", expiresAt: nowMs + 9999) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })
        _ = try await store.load()   // seed cache

        runner.handler = { _, _, _ in throw TestError.boom }   // non-CredentialError failure
        let loaded = try await store.load()
        #expect(loaded.accessToken == "cached")
    }

    // Covers R4: transient corrupt Keychain JSON falls back to a known-good cache instead of hard-failing.
    @Test func decodingFailedFallsBackToCacheWhenPresent() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(fixedNow.timeIntervalSince1970 * 1000)
        let runner = FakeCommandRunner()
        runner.handler = { _, _, _ in self.blob(access: "cached", expiresAt: nowMs + 9999) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow })
        _ = try await store.load()   // seed cache

        runner.handler = { _, _, _ in "corrupt not json" }
        let loaded = try await store.load()
        #expect(loaded.accessToken == "cached")
    }
}
