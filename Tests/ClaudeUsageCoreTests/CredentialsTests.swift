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

    private func futureExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) + 100 * 60 * 1000 }
    private func pastExpiry(_ now: Date) -> Int { Int(now.timeIntervalSince1970 * 1000) - 1000 }

    @Test func decodesKeychainBlob() throws {
        let store = CredentialStore(runner: FakeCommandRunner())
        let creds = try store.decodeEnvelope(blob(access: "tok-a", refresh: "tok-r", expiresAt: 12345))
        #expect(creds.accessToken == "tok-a")
        #expect(creds.expiresAt == 12345)
    }

    @Test func loadReadsFromKeychain() async throws {
        let runner = FakeCommandRunner { exe, args in
            #expect(exe == "/usr/bin/security")
            #expect(args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            return self.blob(access: "from-keychain")
        }
        let store = CredentialStore(runner: runner)
        let creds = try await store.load()
        #expect(creds.accessToken == "from-keychain")
    }

    @Test func isExpiredHonorsFiveMinuteBuffer() {
        let store = CredentialStore(runner: FakeCommandRunner())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        let valid = ClaudeCredentials(accessToken: "a", expiresAt: nowMs + 10 * 60 * 1000)
        let nearExpiry = ClaudeCredentials(accessToken: "a", expiresAt: nowMs + 2 * 60 * 1000)
        let past = ClaudeCredentials(accessToken: "a", expiresAt: nowMs - 1000)

        let atBoundary = ClaudeCredentials(accessToken: "a", expiresAt: nowMs + 5 * 60 * 1000)
        let justInside = ClaudeCredentials(accessToken: "a", expiresAt: nowMs + 5 * 60 * 1000 + 1)

        #expect(store.isExpired(valid, now: now) == false)
        #expect(store.isExpired(nearExpiry, now: now) == true)  // within 5-min buffer
        #expect(store.isExpired(past, now: now) == true)
        #expect(store.isExpired(atBoundary, now: now) == true)   // exactly at the buffer edge → expired
        #expect(store.isExpired(justInside, now: now) == false)  // 1ms inside the buffer → still valid
    }

    // Happy path: a non-expired token reports usable.
    @Test func currentTokenReportsValidWhenNotExpired() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in self.blob(access: "live", expiresAt: self.futureExpiry(fixedNow)) }
        let store = CredentialStore(runner: runner, now: { fixedNow })

        let snap = try await store.currentToken()
        #expect(snap.accessToken == "live")
        #expect(snap.isExpired == false)
    }

    // Edge: an expired token is still returned (with the flag set) — read-only never refreshes it.
    @Test func currentTokenReportsExpiredButStillReturnsToken() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in self.blob(access: "stale", expiresAt: self.pastExpiry(fixedNow)) }
        let store = CredentialStore(runner: runner, now: { fixedNow })

        let snap = try await store.currentToken()
        #expect(snap.accessToken == "stale")
        #expect(snap.isExpired == true)
    }

    // Core guarantee: the store NEVER writes the Keychain (no add-generic-password) — only reads.
    @Test func neverWritesKeychain() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in self.blob(access: "x", expiresAt: self.pastExpiry(fixedNow)) }
        let store = CredentialStore(runner: runner, now: { fixedNow })

        _ = try await store.currentToken()
        _ = try await store.load()

        #expect(!runner.calls.isEmpty)
        #expect(runner.calls.allSatisfy { $0.arguments.first == "find-generic-password" })
        #expect(!runner.calls.contains { $0.arguments.contains("add-generic-password") })
    }

    @Test func loadThrowsWhenKeychainFailsAndNoFallback() async {
        let runner = FakeCommandRunner { _, _ in throw TestError.boom }
        let store = CredentialStore(runner: runner, fallbackFileURL: nonexistentFallback())
        await #expect(throws: CredentialError.notAuthenticated) { try await store.load() }
    }

    @Test func loadFallsBackToCredentialsFile() async throws {
        let runner = FakeCommandRunner { _, _ in throw TestError.boom }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        try blob(access: "from-file").data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = CredentialStore(runner: runner, fallbackFileURL: tmp)
        let creds = try await store.load()
        #expect(creds.accessToken == "from-file")
    }

    // Corrupt Keychain JSON surfaces decodingFailed (not masked by the file fallback).
    @Test func decodingFailedFromKeychainStillThrows() async throws {
        let runner = FakeCommandRunner { _, _ in "not json at all" }
        let store = CredentialStore(runner: runner, fallbackFileURL: nonexistentFallback())
        var thrown: CredentialError?
        do { _ = try await store.load() } catch let error as CredentialError { thrown = error }
        guard case .decodingFailed = thrown else {
            Issue.record("expected decodingFailed, got \(String(describing: thrown))")
            return
        }
    }

    // A slow/blocking runner is awaited off the actor executor and still resolves correctly.
    @Test func currentTokenCompletesWithSlowRunner() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_000_000)
        let runner = FakeCommandRunner { _, _ in
            Thread.sleep(forTimeInterval: 0.1)
            return self.blob(access: "slow-but-ok", expiresAt: self.futureExpiry(fixedNow))
        }
        let store = CredentialStore(runner: runner, now: { fixedNow })
        let snap = try await store.currentToken()
        #expect(snap.accessToken == "slow-but-ok")
    }
}
