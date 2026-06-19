import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite @MainActor struct AppStateTests {
    /// A store backed by a throwaway temp file so tests never touch the real Application Support
    /// copy. Each call is a fresh, empty location unless explicitly seeded.
    private func tempStore() -> LastUsageStore {
        LastUsageStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("appstate-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("last-usage.json"))
    }

    @Test func refreshSuccessTransitionsToLoaded() async {
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 42, sevenDay: 7)))
        let fixedNow = Date(timeIntervalSince1970: 5_000_000)
        let state = AppState(client: client, lastUsageStore: tempStore(), now: { fixedNow })

        await state.refresh()

        #expect(state.phase == .loaded)
        #expect(state.usage?.fiveHour?.utilization == 42)
        #expect(state.usage?.sevenDay?.utilization == 7)
        #expect(state.lastUpdated == fixedNow)
        #expect(state.errorMessage == nil)
    }

    // Hard errors (e.g. HTTP 5xx) stay fail-soft: keep previous usage, surface an error.
    @Test func hardErrorRetainsPreviousUsageAsError() async {
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 30)))
        let state = AppState(client: client, lastUsageStore: tempStore())

        await state.refresh()                       // seed good data
        #expect(state.usage?.fiveHour?.utilization == 30)

        client.result = .failure(UsageError.http(status: 500, body: ""))
        await state.refresh()

        #expect(state.phase == .error)
        #expect(state.errorMessage != nil)
        #expect(state.usage?.fiveHour?.utilization == 30)  // fail-soft: previous data kept
    }

    // Token expiry is a soft stale state, not an error — usage is retained, no refresh attempted.
    @Test func unauthorizedBecomesStaleRetainingUsage() async {
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 55)))
        let state = AppState(client: client, lastUsageStore: tempStore())

        await state.refresh()                       // seed good data
        client.result = .failure(UsageError.unauthorized)
        await state.refresh()

        #expect(state.phase == .stale)
        #expect(state.usage?.fiveHour?.utilization == 55)  // last-known retained
        #expect(state.errorMessage?.contains("Claude Code") == true)
    }

    @Test func tokenExpiredBecomesStale() async {
        let client = FakeUsageClient(result: .failure(UsageError.tokenExpired))
        let state = AppState(client: client, lastUsageStore: tempStore())

        await state.refresh()
        #expect(state.phase == .stale)
    }

    @Test func notAuthenticatedWithNoUsageIsStaleWithSignInMessage() async {
        let client = FakeUsageClient(result: .failure(CredentialError.notAuthenticated))
        let state = AppState(client: client, lastUsageStore: tempStore())

        await state.refresh()
        #expect(state.phase == .stale)
        #expect(state.usage == nil)
        #expect(state.errorMessage?.lowercased().contains("sign in") == true)
    }

    // Recovery: a stale tick followed by a good fetch returns to loaded.
    @Test func recoversFromStaleToLoaded() async {
        let client = FakeUsageClient(result: .failure(UsageError.tokenExpired))
        let state = AppState(client: client, lastUsageStore: tempStore())

        await state.refresh()
        #expect(state.phase == .stale)

        client.result = .success(.sample(fiveHour: 12))
        await state.refresh()
        #expect(state.phase == .loaded)
        #expect(state.usage?.fiveHour?.utilization == 12)
    }

    // Launch shows real last-known data immediately from the persisted store.
    @Test func launchLoadsPersistedUsageImmediately() async {
        let store = tempStore()
        let savedAt = Date(timeIntervalSince1970: 4_000_000)
        store.save(.sample(fiveHour: 77, sevenDay: 11), at: savedAt)

        let client = FakeUsageClient(result: .failure(UsageError.tokenExpired))
        let state = AppState(client: client, lastUsageStore: store)

        // Populated before any network call.
        #expect(state.usage?.fiveHour?.utilization == 77)
        #expect(state.lastUpdated == savedAt)
        #expect(state.phase == .stale)
    }

    // A successful fetch persists usage so a later launch can restore it.
    @Test func successPersistsUsageToStore() async {
        let store = tempStore()
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 64, sevenDay: 9)))
        let state = AppState(client: client, lastUsageStore: store)

        await state.refresh()

        let restored = store.load()
        #expect(restored?.usage.fiveHour?.utilization == 64)
        #expect(restored?.usage.sevenDay?.utilization == 9)
    }

    @Test func startPollingFetchesImmediatelyAndSchedules() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client, lastUsageStore: tempStore())

        state.startPolling()
        await state.lastRefreshTask?.value

        #expect(client.callCount == 1)
        #expect(state.isPolling == true)
        #expect(state.phase == .loaded)
    }

    @Test func manualRefreshFetchesAgain() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client, lastUsageStore: tempStore())

        state.startPolling()
        await state.lastRefreshTask?.value
        state.manualRefresh()
        await state.lastRefreshTask?.value

        #expect(client.callCount == 2)
        #expect(state.isPolling == true)
    }

    @Test func pollTickPerformsFetch() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client, lastUsageStore: tempStore())

        state.pollTick()
        await state.lastRefreshTask?.value

        #expect(client.callCount == 1)
    }

    @Test func overlappingRefreshesResolveConsistently() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client, lastUsageStore: tempStore())

        state.manualRefresh()
        state.manualRefresh()
        await state.lastRefreshTask?.value

        #expect(state.phase == .loaded)
        #expect(state.usage != nil)
    }

    @Test func stopEndsPolling() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client, lastUsageStore: tempStore())
        state.startPolling()
        await state.lastRefreshTask?.value

        state.stop()
        #expect(state.isPolling == false)
    }

    // describe() maps errors to actionable text — never "error N".
    @Test func describeMapsCredentialErrorsToActionableText() {
        let cases: [CredentialError] = [
            .notAuthenticated,
            .commandFailed(status: 1, message: ""),
            .commandTimedOut,
            .decodingFailed("x"),
        ]
        for error in cases {
            let text = AppState.describe(error)
            #expect(!text.contains("CredentialError"))
            #expect(!text.lowercased().contains("error 1"))
            #expect(text.contains("Claude Code") || text.contains("Keychain"))
        }
        #expect(AppState.describe(UsageError.http(status: 500, body: "")).contains("500"))
        #expect(AppState.isStale(UsageError.tokenExpired))
        #expect(AppState.isStale(UsageError.unauthorized))
        #expect(AppState.isStale(CredentialError.notAuthenticated))
        #expect(!AppState.isStale(UsageError.http(status: 500, body: "")))
    }
}
