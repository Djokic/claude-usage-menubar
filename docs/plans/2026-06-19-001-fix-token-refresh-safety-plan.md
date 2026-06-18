---
title: "fix: Make OAuth token refresh and keychain writes safe"
type: fix
status: active
created: 2026-06-19
depth: standard
---

# fix: Make OAuth token refresh and keychain writes safe

The menu bar app refreshes the Claude OAuth token when it's expired and writes the rotated
tokens back into the shared `Claude Code-credentials` Keychain item. That behavior is kept (so
the monitor works even when Claude Code is idle), but the **way** it's done is unsafe in three
ways this plan fixes: concurrent refreshes race on the single-use refresh token, the blocking
`security` subprocess can stall the app on a Keychain prompt, and the secret is passed on the
command line where any same-user process can read it.

---

## Problem Frame

`CredentialStore` (`Sources/ClaudeUsageCore/Credentials.swift`) backs every usage fetch. On each
60-second poll (and on a 401 retry, and on manual refresh) it loads credentials from the Keychain
via the `security` CLI, and if the access token is within 5 minutes of expiry it POSTs the refresh
token to the OAuth endpoint and persists the new (rotated) tokens back.

Three latent defects — all flagged P1 by the prior code review (`docs/residual-review-findings/feat-claude-usage-menubar.md`, findings #1, #2, #4; #7 is adjacent) — make this risky:

1. **No single-flight.** `CredentialStore` is a plain class with no serialization. Two refreshes can run at once (poll tick overlapping a manual refresh or 401 retry; or our app vs. Claude Code). Both read the same refresh token and POST it; the server rotates on the first and rejects the second — invalidating a token that may be shared with Claude Code.
2. **Blocking subprocess on a structured-concurrency thread.** `ProcessCommandRunner.run()` calls `process.waitUntilExit()` synchronously and is invoked from `async` contexts. A Keychain approval dialog makes `security` block indefinitely, pinning a Swift cooperative-pool thread (and the actor/main actor by extension). There is also no timeout.
3. **Token in argv.** `persist()` runs `security add-generic-password … -w <json>`, passing the full credentials JSON (access + refresh token) as a process argument, readable by any same-UID process via `ps`.

Adjacent, in the same subprocess code: stdout is drained fully before stderr, so a large stderr write could deadlock both pipes (#7).

This is a **behavior-preserving safety fix**: the observable behavior (refresh when expired, persist rotated tokens, fall back to `~/.claude/.credentials.json`, fail-soft on error) stays the same; only the concurrency, threading, and secret-handling change.

---

## Requirements

- **R1** — Concurrent refreshes coalesce into a **single** in-flight OAuth refresh, so the rotating refresh token is POSTed exactly once per batch.
- **R2** — The blocking `security` subprocess runs **off** the Swift cooperative thread pool / main actor, and a hung subprocess (e.g., a Keychain prompt) **times out** and fails soft instead of hanging the app.
- **R3** — The credentials JSON is **never** passed as a process argument; it is fed to `security` via **stdin**.
- **R4** — Behavior is preserved: still refresh + persist rotated tokens (works when Claude Code is idle), still fall back to the credentials file, and the icon/tooltip/poll behavior is unchanged.
- **R5** — While reworking the subprocess code, drain stdout and stderr **concurrently** (no two-pipe deadlock) and apply a request timeout to the refresh POST.

---

## Scope Boundaries

**In scope:** `CredentialStore` and `ProcessCommandRunner`/`CommandRunner` concurrency and secret-handling, and the matching tests. The OAuth refresh request gains a timeout.

### Deferred to Follow-Up Work
- A timeout on the **usage GET** request (`UsageClient`/`URLSessionTransport`) — review finding #3. Same class of fix but a separate code path from the refresh/keychain concern; do it next.
- The remaining recorded review items (test-coverage gaps #8–#13, bundle-id #14) are unrelated to this change.

### Out of Scope (Non-Goals)
- Switching to a **read-only** credential model (we explicitly chose to keep refresh+persist).
- Replacing the `security` CLI with the `SecItem*` framework wholesale — considered only as a *fallback* for the stdin write (see U4 risk), not a goal.
- Any UI, ring, or polling-cadence change.

---

## Key Technical Decisions

1. **`CredentialStore` becomes an `actor`.** This serializes all credential operations (giving us a home for single-flight state), removes the current `@unchecked Sendable`, and makes the concurrency safe by construction. `TokenProvider`'s async requirements are satisfied by the actor; `UsageClient` already `await`s them, so it needs no change. `isExpired`/`decodeEnvelope` stay pure (nonisolated or plain), `load`/`persist`/`refresh` become async actor methods.

2. **Subprocess runs off the actor's executor.** A blocking `runner.run(...)` called directly inside an actor method would block a cooperative thread — the exact bug. So the actor wraps every runner call in `withCheckedThrowingContinuation` dispatched to a background `DispatchQueue`; the actor `await`s it and suspends (freeing the executor) while `security` runs elsewhere. The blocking primitive (`CommandRunner.run`) stays synchronous and simple — the actor owns the async orchestration.

3. **Single-flight via an in-flight `Task`.** The actor holds `inFlightRefresh: Task<ClaudeCredentials, Error>?`. `refresh()` returns the existing task's value when one is in flight (actor reentrancy during `await` is what lets concurrent callers join), otherwise starts one, stores it, and clears it on completion. One POST, one rotation, per coalesced batch. A refresh started *after* the previous completes is a genuinely new task.

4. **Persist via stdin, not argv.** `persist()` invokes `security add-generic-password -U -a claude-cli -s "Claude Code-credentials" -w` with **no value after `-w`** and pipes the JSON to **stdin** (`security` reads the password from stdin when `-w` has no inline value). The `security` CLI stays the Keychain accessor, preserving the working ACL (no new approval prompt) — only the secret's transport changes. Verify the stdin behavior at execution; fall back to `SecItem*` if the CLI won't read a piped secret (see Risks).

5. **Timeout kills a hung subprocess.** `ProcessCommandRunner` schedules a watchdog that `terminate()`s the process after N seconds and throws a `commandTimedOut` error, so a Keychain prompt that never gets answered fails soft on the next poll instead of wedging the app. A modest timeout (e.g., ~10s) is generous for a local Keychain op.

---

## High-Level Technical Design

*Directional guidance for review, not implementation specification.*

```text
   UsageClient.fetchUsage() ── await ──▶ actor CredentialStore
                                          │  validAccessToken() / forceRefreshAccessToken()
                                          │     └─ load() ─┐
                                          │  refresh() ────┤  (single-flight: inFlightRefresh Task)
                                          │     └─ POST (timeout) → persist() ┐
                                          ▼                                   │
                              runOffActor { … }  ──suspends actor──▶ DispatchQueue.global()
                                          ▼                                   │
                              CommandRunner.run(args, stdin:)  ── blocking ───┘
                              (ProcessCommandRunner: stdin pipe, concurrent
                               stdout/stderr drain, watchdog timeout → kill)
```

Concurrent callers (poll tick + manual refresh + 401 retry) all reach `refresh()`; the first creates the in-flight task, the rest await it → one OAuth round-trip, one persist. Every Keychain read/write happens on a background queue thread the actor awaits, never on the actor's own executor.

---

## Implementation Units

Dependency order: **U1** → **U2** → (**U3**, **U4**).

### U1. Harden the command runner (stdin, concurrent drain, timeout)

**Goal:** `ProcessCommandRunner` accepts optional stdin, drains stdout and stderr concurrently, and terminates + throws on a timeout. Extend the `CommandRunner` seam accordingly.
**Requirements:** R2, R3, R5.
**Dependencies:** none.
**Files:** `Sources/ClaudeUsageCore/Transport.swift`, `Tests/ClaudeUsageCoreTests/CommandRunnerTests.swift` (new).
**Approach:**
- Change the protocol to `run(_ executable: String, _ arguments: [String], stdin: String?) throws -> String` (keep it synchronous/blocking — the actor handles async). Add a `commandTimedOut` case to `CredentialError`.
- `ProcessCommandRunner`: write `stdin` to the input pipe and close it; read stdout and stderr **concurrently** (two background reads, or `readabilityHandler` accumulation) so neither pipe can fill and deadlock; schedule a watchdog (`DispatchQueue.asyncAfter`) that `terminate()`s the process past the timeout and surfaces `commandTimedOut`.
- Update the `FakeCommandRunner` (in `Fakes.swift`) to the new signature and record the received `stdin`.
**Patterns to follow:** existing `ProcessCommandRunner` in `Transport.swift`.
**Test scenarios** (use harmless real binaries — `/bin/cat`, `/bin/echo`, `/bin/sleep`, a `/bin/sh -c` writer — never the Keychain):
- Covers R3. stdin is delivered: `run("/bin/cat", [], stdin: "hello")` returns `"hello"`.
- Non-zero exit throws `commandFailed` carrying stderr text.
- Covers R5. A command that writes large output to **both** stdout and stderr returns the full stdout without deadlocking.
- Covers R2. A hanging command (`/bin/sleep 5`) with a ~1s timeout throws `commandTimedOut` within ~1–2s and leaves no surviving child process.
- No-stdin call still works (back-compat with `stdin: nil`).

### U2. Convert `CredentialStore` to an actor with off-executor subprocess execution

**Goal:** `CredentialStore` is an `actor`; every `security` call runs off the actor's executor so a slow/blocked Keychain op never stalls the cooperative pool or main actor.
**Requirements:** R2, R4.
**Dependencies:** U1.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Tests/ClaudeUsageCoreTests/CredentialsTests.swift`.
**Approach:**
- `actor CredentialStore: TokenProvider` (drop `final class … @unchecked Sendable`). Keep injected `runner`/`transport`/`now`/`fallbackFileURL`.
- Add `private func runOffActor(_ args…) async throws -> String` wrapping `runner.run` in `withCheckedThrowingContinuation` + `DispatchQueue.global().async`. `load()` and `persist()` become `async` and call it; `isExpired`/`decodeEnvelope` stay synchronous pure helpers (mark `nonisolated` where they take no actor state).
- `validAccessToken()`/`forceRefreshAccessToken()`/`refresh()` stay async (now actor-isolated).
- The credentials-file fallback read is filesystem I/O, not the cooperative-pool concern; keep it but it can also go through `runOffActor`-style off-loading if convenient.
**Patterns to follow:** current method bodies in `Credentials.swift` (logic unchanged, only isolation/threading).
**Test scenarios** (existing `CredentialsTests` updated to `await` actor methods):
- `validAccessToken()` returns the current token and makes **no** POST when not expired.
- Covers R4. `validAccessToken()` triggers a refresh and returns the new token when expired.
- `load()` falls back to `~/.claude/.credentials.json` when the runner throws; throws `notAuthenticated` when the read fails and no fallback exists; surfaces `decodingFailed` (not fallback) on malformed Keychain JSON.
- Covers R2. With a runner that sleeps briefly before returning, `validAccessToken()` still completes correctly and concurrently-scheduled work is not blocked (a second actor call can interleave).
- `isExpired` 5-minute-buffer boundary unchanged (valid / near-expiry / past).

### U3. Single-flight refresh coalescing

**Goal:** Concurrent `refresh()` / `forceRefreshAccessToken()` calls share one in-flight refresh; the refresh token is POSTed once per batch.
**Requirements:** R1, R5.
**Dependencies:** U2.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Tests/ClaudeUsageCoreTests/CredentialsTests.swift`.
**Approach:**
- Add `private var inFlightRefresh: Task<ClaudeCredentials, Error>?`. `refresh()`: if a task is in flight, `return try await it.value`; else create `Task { try await performRefresh() }`, store it, await, and clear it on completion (success or failure). `performRefresh()` holds the existing load → POST → persist body.
- Apply `request.timeoutInterval` (~15–20s) to the refresh `URLRequest` (R5).
**Patterns to follow:** the existing `refresh()` body becomes `performRefresh()`.
**Test scenarios:**
- Covers R1. Many concurrent `refresh()` calls → the transport records **exactly one** POST; every caller receives the same rotated credentials. (Use a transport whose response is gated/delayed so the calls genuinely overlap.)
- A `refresh()` issued **after** the prior one resolves starts a **new** POST (no stale coalescing).
- When the in-flight refresh throws, all awaiting callers get the error and a subsequent `refresh()` retries with a fresh task.
- Covers R1. With the token expired, concurrent `validAccessToken()` calls cause only one refresh POST.

### U4. Secure keychain persist via stdin

**Goal:** Persist the credentials JSON to `security` over stdin; the token never appears in argv.
**Requirements:** R3.
**Dependencies:** U1, U2.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Tests/ClaudeUsageCoreTests/CredentialsTests.swift`.
**Approach:** `persist()` calls the runner with args `["add-generic-password","-U","-a",account,"-s",service,"-w"]` (trailing `-w`, no value) and `stdin: json`. Verify at execution that `security` reads the piped secret non-interactively; if it requires a TTY, fall back to `SecItem*` (see Risks) or document the limitation.
**Patterns to follow:** current `persist()` in `Credentials.swift`.
**Test scenarios:**
- Covers R3. `persist()` passes the JSON via **stdin** and **no** argument equals the JSON/token (assert `FakeCommandRunner.lastStdin == json` and none of the recorded args contains the access/refresh token).
- Args include `-U`, `-a claude-cli`, `-s "Claude Code-credentials"`, and a trailing `-w` with no value.
- Special characters in the secret round-trip intact through stdin.
- **Execution-time check** (not a unit test): manually confirm a piped `security … -w` write then read-back succeeds on the target macOS; if not, switch to the `SecItem*` fallback.

---

## System-Wide Impact

The one external touch point is unchanged in *intent* — the app still reads and rewrites the shared `Claude Code-credentials` Keychain item — but it is made safe: a single coalesced rotation instead of racy concurrent ones (less chance of disrupting a running Claude Code session), no thread-blocking on a Keychain prompt, and no token in argv. No other component changes; `UsageClient`, `AppState`, `AppDelegate`, the renderer, and the UI are untouched (they consume `TokenProvider`/`UsageClient` through unchanged async signatures).

---

## Risks & Mitigations

- **R-A — `security … -w` may not read a piped stdin secret (could require a TTY).** If so, U4's primary approach fails. *Mitigation:* verify with a throwaway Keychain item during execution; fall back to the `SecItem*` framework for the write (accepting it changes the Keychain accessor identity and may prompt once), or keep argv as a last resort with the risk documented. This is an execution-time unknown, not a planning blocker.
- **R-B — Actor reentrancy.** The single-flight pattern relies on reentrancy during `await`; a careless `await` between checking and setting `inFlightRefresh` could still double-start. *Mitigation:* set the task synchronously right after the nil-check with no intervening `await`; cover with the concurrent-refresh test.
- **R-C — Watchdog races process exit.** The timeout could `terminate()` a process that just finished. *Mitigation:* cancel the watchdog as soon as the process exits; treat a benign post-exit terminate as a no-op.
- **R-D — Test flakiness from real subprocesses/timing.** U1/U3 tests use real binaries and overlapping tasks. *Mitigation:* generous timeouts, gated/deterministic transport for the coalescing test, and small fixed sleeps rather than tight timing assertions.

---

## Verification Strategy

- **Automated (`swift test`):** the per-unit scenarios above — runner stdin/timeout/concurrent-drain (real harmless binaries), actor load/refresh/expiry behavior, single-flight POST-once under concurrency, and stdin-only persist. The existing 43 tests must still pass (with `await` added where `CredentialStore` calls became actor-isolated).
- **Manual:** `./build.sh && ./ClaudeUsage.app/Contents/MacOS/ClaudeUsageApp --once` still prints live usage (auth path intact); force a near-expiry refresh if practical and confirm the Keychain item is updated and Claude Code remains logged in; confirm `ps` during a refresh shows no token in `security`'s arguments.

---

## Deferred Implementation Notes

- Exact timeout values (subprocess watchdog; refresh request) — start ~10s / ~15–20s, tune if needed.
- Whether `decodeEnvelope`/`isExpired` are best expressed as `nonisolated` actor members or free functions — decide while converting.
- The precise off-actor bridging shape (`withCheckedThrowingContinuation` + `DispatchQueue.global()` vs. a small `Task.detached`) — pick whichever reads cleanly and provably leaves the actor executor free.
- The stdin-vs-`SecItem` outcome for U4 (per Risk R-A) is resolved during execution.
