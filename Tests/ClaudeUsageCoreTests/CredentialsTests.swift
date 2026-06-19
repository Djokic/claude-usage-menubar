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

    /// An isolated write-access flag so tests never read/write the shared standard defaults.
    private func writeStore(granted: Bool? = nil) -> WriteAccessStore {
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "creds-tests-\(UUID().uuidString)")!,
                                     key: "granted")
        store.granted = granted
        return store
    }

    private func futureExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) + 100 * 60 * 1000 }
    private func pastExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) - 1000 }

    // MARK: Decoding / reading

    @Test func decodesKeychainBlob() throws {
        let store = CredentialStore(runner: FakeCommandRunner(), transport: FakeTransport())
        let creds = try store.decodeEnvelope(blob(access: "tok-a", refresh: "tok-r", expiresAt: 12345))
        #expect(creds.accessToken == "tok-a")
        #expect(creds.refreshToken == "tok-r")
        #expect(creds.expiresAt == 12345)
    }

    @Test func loadReadsFromKeychain() async throws {
        let runner = FakeCommandRunner { exe, args in
            #expect(exe == "/usr/bin/security")
            #expect(args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            return self.blob(access: "from-keychain")
        }
        let store = CredentialStore(runner: runner, transport: FakeTransport())
        #expect(try await store.load().accessToken == "from-keychain")
    }

    @Test func isExpiredHonorsFiveMinuteBuffer() {
        let store = CredentialStore(runner: FakeCommandRunner(), transport: FakeTransport())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        let valid = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 10 * 60 * 1000)
        let nearExpiry = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 2 * 60 * 1000)
        let atBoundary = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 5 * 60 * 1000)
        let justInside = ClaudeCredentials(accessToken: "a", refreshToken: "r", expiresAt: nowMs + 5 * 60 * 1000 + 1)

        #expect(store.isExpired(valid, now: now) == false)
        #expect(store.isExpired(nearExpiry, now: now) == true)
        #expect(store.isExpired(atBoundary, now: now) == true)
        #expect(store.isExpired(justInside, now: now) == false)
    }

    @Test func loadThrowsWhenKeychainFailsAndNoFallback() async {
        let runner = FakeCommandRunner { _, _ in throw TestError.boom }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: nonexistentFallback())
        await #expect(throws: CredentialError.notAuthenticated) { try await store.load() }
    }

    @Test func loadFallsBackToCredentialsFile() async throws {
        let runner = FakeCommandRunner { _, _ in throw TestError.boom }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        try blob(access: "from-file").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: tmp)
        #expect(try await store.load().accessToken == "from-file")
    }

    @Test func decodingFailedFromKeychainStillThrows() async throws {
        let runner = FakeCommandRunner { _, _ in "not json at all" }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), fallbackFileURL: nonexistentFallback())
        var thrown: CredentialError?
        do { _ = try await store.load() } catch let error as CredentialError { thrown = error }
        guard case .decodingFailed = thrown else {
            Issue.record("expected decodingFailed, got \(String(describing: thrown))")
            return
        }
    }

    // MARK: currentToken — adaptive

    @Test func currentTokenReportsValidWhenNotExpired() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in self.blob(access: "live", expiresAt: self.futureExpiry(fixedNow)) }
        let store = CredentialStore(runner: runner, transport: FakeTransport(), now: { fixedNow }, writeAccessStore: writeStore())
        let snap = try await store.currentToken()
        #expect(snap.accessToken == "live")
        #expect(snap.isExpired == false)
        #expect(!runner.didWriteKeychain)  // valid token → no refresh, no write
    }

    // Read-only (write denied): an expired token is returned expired, with NO refresh and NO write.
    @Test func currentTokenExpiredReadOnlyDoesNotRefreshOrQuery() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in self.blob(access: "stale", expiresAt: self.pastExpiry(fixedNow)) }
        let transport = FakeTransport()
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: false))

        let snap = try await store.currentToken()
        #expect(snap.accessToken == "stale")
        #expect(snap.isExpired == true)
        #expect(transport.requests.isEmpty)   // never POSTed a refresh
        #expect(!runner.didWriteKeychain)      // never wrote the Keychain
    }

    // Write granted: an expired token triggers a refresh and a fresh (non-expired) token.
    @Test func currentTokenExpiredWriteGrantedRefreshes() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(access: "stale", refresh: "old", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = #"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: true))

        let snap = try await store.currentToken()
        #expect(snap.accessToken == "fresh")
        #expect(snap.isExpired == false)
        #expect(transport.requests.count == 1)
        #expect(runner.didWriteKeychain)  // rotated token written back
    }

    // Write granted but the refresh POST fails: fall back to the current token as stale (no throw).
    @Test func currentTokenRefreshFailureFallsBackToStale() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(access: "stale", refresh: "old", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let transport = FakeTransport(stubs: [.init(Data(), 500)])  // refresh POST fails
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: true))

        let snap = try await store.currentToken()
        #expect(snap.accessToken == "stale")
        #expect(snap.isExpired == true)   // caller will show stale, not query
    }

    // MARK: Write-access probe

    @Test func ensureWriteAccessProbedGrantsOnSuccessfulWrite() async {
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(access: "tok") : ""
        }
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "probe-\(UUID().uuidString)")!, key: "g")
        let cred = CredentialStore(runner: runner, transport: FakeTransport(), writeAccessStore: store)

        await cred.ensureWriteAccessProbed()
        #expect(store.granted == true)
        #expect(runner.didWriteKeychain)
    }

    @Test func ensureWriteAccessProbedDeniesOnWriteFailure() async {
        let runner = FakeCommandRunner { _, args in
            if args.first == "find-generic-password" { return self.blob(access: "tok") }
            throw CredentialError.commandFailed(status: 1, message: "denied")  // write denied
        }
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "probe-\(UUID().uuidString)")!, key: "g")
        let cred = CredentialStore(runner: runner, transport: FakeTransport(), writeAccessStore: store)

        await cred.ensureWriteAccessProbed()  // must not throw
        #expect(store.granted == false)
    }

    @Test func ensureWriteAccessProbedSkipsWhenAlreadyDecided() async {
        let runner = FakeCommandRunner { _, _ in self.blob(access: "tok") }
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "probe-\(UUID().uuidString)")!, key: "g")
        store.granted = true  // already decided
        let cred = CredentialStore(runner: runner, transport: FakeTransport(), writeAccessStore: store)

        await cred.ensureWriteAccessProbed()
        #expect(!runner.didWriteKeychain)  // no probe write performed
    }

    @Test func probeWritesExactBytesReadBackVerbatim() async {
        let raw = blob(access: "verbatim-acc", refresh: "verbatim-ref", expiresAt: 999)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? raw + "\n" : ""  // -w appends a display newline
        }
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "probe-\(UUID().uuidString)")!, key: "g")
        let cred = CredentialStore(runner: runner, transport: FakeTransport(), writeAccessStore: store)

        await cred.ensureWriteAccessProbed()
        let stdin = try! #require(runner.lastWriteStdin)
        // The exact stored value (trimmed of the display newline) is fed back, no re-encoding.
        #expect(stdin.contains(raw))
        #expect(stdin.split(separator: "\n").first.map(String.init) == raw)
    }

    // MARK: Refresh

    @Test func refreshBuildsCorrectPostBodyFromFreshRead() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(refresh: "fresh-refresh", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = #"{"access_token":"a","refresh_token":"b","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: true))

        _ = try await store.refresh()
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://console.anthropic.com/v1/oauth/token")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["grant_type"] == "refresh_token")
        #expect(json["refresh_token"] == "fresh-refresh")
        #expect(json["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    }

    @Test func refreshComputesExpiryAndPersistsViaStdinNotArgv() async throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(refresh: "old", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = #"{"access_token":"new-acc","refresh_token":"rotated-secret","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: true))

        let creds = try await store.refresh()
        #expect(creds.accessToken == "new-acc")
        #expect(creds.expiresAt == Int(fixedNow.timeIntervalSince1970 * 1000) + 3600 * 1000)
        let stdin = try #require(runner.lastWriteStdin)
        #expect(stdin.contains("rotated-secret"))                    // secret travels via stdin
        #expect(!runner.calls.contains { $0.arguments.contains(where: { $0.contains("rotated-secret") }) })  // never in argv
    }

    @Test func concurrentRefreshesCoalesceIntoOnePost() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args in
            args.first == "find-generic-password" ? self.blob(refresh: "old", expiresAt: self.pastExpiry(fixedNow)) : ""
        }
        let refreshJSON = #"{"access_token":"coalesced","refresh_token":"rotated","expires_in":3600}"#.data(using: .utf8)!
        let transport = FakeTransport(stubs: [.init(refreshJSON, 200)])  // only ONE response
        transport.delay = 0.2
        let store = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: writeStore(granted: true))

        let results = try await withThrowingTaskGroup(of: ClaudeCredentials.self) { group in
            for _ in 0..<8 { group.addTask { try await store.refresh() } }
            var all: [ClaudeCredentials] = []
            for try await r in group { all.append(r) }
            return all
        }
        #expect(transport.requests.count == 1)
        #expect(results.allSatisfy { $0.accessToken == "coalesced" })
    }

    // Persist failure after a successful POST is non-fatal AND downgrades the grant to read-only.
    @Test func persistFailureIsNonFatalAndDowngradesGrant() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, args in
            if args.first == "find-generic-password" { return self.blob(refresh: "old", expiresAt: self.pastExpiry(fixedNow)) }
            throw CredentialError.commandFailed(status: 1, message: "denied")  // write-back denied
        }
        let json1 = #"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.data(using: .utf8)!
        let store = WriteAccessStore(defaults: UserDefaults(suiteName: "downgrade-\(UUID().uuidString)")!, key: "g")
        store.granted = true
        let transport = FakeTransport(stubs: [.init(json1, 200)])
        let cred = CredentialStore(runner: runner, transport: transport, now: { fixedNow }, writeAccessStore: store)

        let creds = try await cred.refresh()   // must NOT throw despite persist failure
        #expect(creds.accessToken == "a1")
        #expect(store.granted == false)         // downgraded so we stop consuming the token

        // A subsequent expired currentToken now behaves read-only: no further POST.
        let snap = try await cred.currentToken()
        #expect(snap.isExpired == true)
        #expect(transport.requests.count == 1)  // no second refresh attempt
    }
}
