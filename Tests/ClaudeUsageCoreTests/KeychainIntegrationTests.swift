import Testing
import Foundation
@testable import ClaudeUsageCore

/// End-to-end tests against the REAL `security` CLI on a scratch Keychain item — the layer fakes
/// cannot vouch for. v1's write path used the stdin password prompt, which silently truncates at
/// 128 bytes and corrupted the stored credentials; these tests pin the actual CLI behavior of the
/// current write path for both the `-i` stdin form and the argv fallback.
@Suite(.serialized) struct KeychainIntegrationTests {
    private static let service = "ClaudeUsageTests-scratch"
    private static let account = "claude-usage-test"

    private let runner = ProcessCommandRunner()

    private func deleteScratchItem() {
        _ = try? runner.run("/usr/bin/security", ["delete-generic-password", "-s", Self.service])
    }

    private func seed(_ payload: String) throws {
        let hex = CredentialStore.hexEncode(payload)
        _ = try runner.run("/usr/bin/security", [
            "add-generic-password", "-U", "-a", Self.account, "-s", Self.service, "-X", hex,
        ])
    }

    /// The stored secret as the CLI reports it, decoded from the hex display form the real
    /// `security` uses for non-ASCII values (pinned by `realCLIHexPrintsNonASCIISecrets`).
    private func storedSecret() throws -> String {
        CredentialStore.normalizeSecretOutput(
            try runner.run("/usr/bin/security", ["find-generic-password", "-s", Self.service, "-w"])
        )
    }

    private func credentialStore(granted: Bool? = nil) -> (CredentialStore, WriteAccessStore) {
        let flags = WriteAccessStore(defaults: UserDefaults(suiteName: "kc-int-\(UUID().uuidString)")!, key: "g")
        flags.granted = granted
        let store = CredentialStore(
            runner: runner,
            transport: FakeTransport(),
            writeAccessStore: flags,
            service: Self.service
        )
        return (store, flags)
    }

    /// A blob far past every stdin limit (128-byte password prompt, ~4 KB `-i` line once
    /// hex-doubled), with quotes and non-ASCII to prove the hex path needs no quoting.
    private var bigPayload: String {
        """
        {"claudeAiOauth":{"accessToken":"\(String(repeating: "a", count: 3000))","refreshToken":"r","expiresAt":1},"mcpOAuth":{"note":"with \\"quotes\\" and é"}}
        """
    }

    @Test func probeRoundTripsMultiKilobyteBlobByteExact() async throws {
        deleteScratchItem()
        defer { deleteScratchItem() }
        let payload = bigPayload
        try seed(payload)

        let (store, flags) = credentialStore()
        await store.ensureWriteAccessProbed()

        #expect(flags.granted == true)
        #expect(try storedSecret() == payload)  // the "no-op" probe really was a no-op
    }

    @Test func probeRoundTripsSmallBlobViaInlineStdinByteExact() async throws {
        deleteScratchItem()
        defer { deleteScratchItem() }
        let payload = #"{"claudeAiOauth":{"accessToken":"short","refreshToken":"r","expiresAt":1}}"#
        try seed(payload)

        let (store, flags) = credentialStore()
        await store.ensureWriteAccessProbed()

        #expect(flags.granted == true)
        #expect(try storedSecret() == payload)
    }

    @Test func probeDeniesWhenItemIsMissing() async throws {
        deleteScratchItem()

        let (store, flags) = credentialStore()
        await store.ensureWriteAccessProbed()

        #expect(flags.granted == false)
    }

    // Pin the CLI's hex display form: `-w` prints non-ASCII secrets as lowercase hex. If this
    // ever changes, normalizeSecretOutput's assumptions need revisiting.
    @Test func realCLIHexPrintsNonASCIISecrets() throws {
        deleteScratchItem()
        defer { deleteScratchItem() }
        let payload = #"{"note":"café"}"#
        try seed(payload)
        let rawOutput = try runner.run("/usr/bin/security", ["find-generic-password", "-s", Self.service, "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(rawOutput == CredentialStore.hexEncode(payload))
    }

    // Regression pin for the root cause itself: the `security` stdin password prompt REALLY does
    // truncate at 128 bytes without erroring. If Apple ever fixes this, the constraint shaping
    // persistRaw goes away; until then, this documents why the hex/-X path exists.
    @Test func stdinPasswordPromptTruncatesAt128Bytes() throws {
        deleteScratchItem()
        defer { deleteScratchItem() }
        let payload = String(repeating: "x", count: 300)
        _ = try runner.run(
            "/usr/bin/security",
            ["add-generic-password", "-U", "-a", Self.account, "-s", Self.service, "-w"],
            stdin: "\(payload)\n\(payload)\n"
        )
        #expect(try storedSecret().count == 128)
    }
}
