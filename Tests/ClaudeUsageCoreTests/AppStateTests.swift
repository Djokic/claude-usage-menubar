import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite @MainActor struct AppStateTests {
    // Covers R8 (manual refresh success path).
    @Test func refreshSuccessTransitionsToLoaded() async {
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 42, sevenDay: 7)))
        let fixedNow = Date(timeIntervalSince1970: 5_000_000)
        let state = AppState(client: client, now: { fixedNow })

        await state.refresh()

        #expect(state.phase == .loaded)
        #expect(state.usage?.fiveHour?.utilization == 42)
        #expect(state.usage?.sevenDay?.utilization == 7)
        #expect(state.lastUpdated == fixedNow)
        #expect(state.errorMessage == nil)
    }

    @Test func refreshFailureRetainsPreviousUsage() async {
        let client = FakeUsageClient(result: .success(.sample(fiveHour: 30)))
        let state = AppState(client: client)

        await state.refresh()                       // seed good data
        #expect(state.usage?.fiveHour?.utilization == 30)

        client.result = .failure(UsageError.unauthorized)
        await state.refresh()                       // now fails

        #expect(state.phase == .error)
        #expect(state.errorMessage != nil)
        #expect(state.usage?.fiveHour?.utilization == 30)  // fail-soft: previous data kept
    }

    // Covers R7: polling performs an immediate fetch and schedules the repeat.
    @Test func startPollingFetchesImmediatelyAndSchedules() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client)

        state.startPolling()
        await state.lastRefreshTask?.value

        #expect(client.callCount == 1)
        #expect(state.isPolling == true)
        #expect(state.phase == .loaded)
    }

    // Covers R8: manual refresh triggers another fetch and keeps polling active.
    @Test func manualRefreshFetchesAgain() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client)

        state.startPolling()
        await state.lastRefreshTask?.value
        state.manualRefresh()
        await state.lastRefreshTask?.value

        #expect(client.callCount == 2)
        #expect(state.isPolling == true)
    }

    @Test func pollTickPerformsFetch() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client)

        state.pollTick()               // simulates the timer firing
        await state.lastRefreshTask?.value

        #expect(client.callCount == 1)
    }

    @Test func overlappingRefreshesResolveConsistently() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client)

        state.manualRefresh()
        state.manualRefresh()          // cancels the first in-flight task
        await state.lastRefreshTask?.value

        #expect(state.phase == .loaded)
        #expect(state.usage != nil)
    }

    @Test func stopEndsPolling() async {
        let client = FakeUsageClient(result: .success(.sample()))
        let state = AppState(client: client)
        state.startPolling()
        await state.lastRefreshTask?.value

        state.stop()
        #expect(state.isPolling == false)
    }

    // Covers R3/R4: describe() maps every credential error to actionable text — never "error N".
    @Test func describeMapsCredentialErrorsToActionableText() {
        let cases: [CredentialError] = [
            .notAuthenticated,
            .commandFailed(status: 1, message: ""),
            .commandTimedOut,
            .refreshFailed(status: 401, message: ""),
            .decodingFailed("x"),
        ]
        for error in cases {
            let text = AppState.describe(error)
            #expect(!text.contains("CredentialError"))
            #expect(!text.lowercased().contains("error 1"))
            #expect(text.contains("Claude Code") || text.contains("Keychain"))
        }
        // UsageError mapping unchanged.
        #expect(AppState.describe(UsageError.http(status: 500, body: "")).contains("500"))
    }
}
