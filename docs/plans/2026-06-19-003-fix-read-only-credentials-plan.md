---
title: "fix: Read-only credentials — stop logging out Claude Code"
type: fix
status: active
created: 2026-06-19
depth: standard
---

# fix: Read-only credentials — stop logging out Claude Code

## Problem Frame

The menu bar app shares one macOS Keychain item (`Claude Code-credentials`) with the Claude Code CLI. That item holds a **single-use, rotating** OAuth refresh token. Since its first commit, the app has *refreshed* that token when near expiry (and retried on HTTP 401), then written the rotated token back to the Keychain. Refreshing **consumes** the shared refresh token and issues a new one — so the app competes with Claude Code over a one-shot credential.

This logs Claude Code out through two mechanisms, **both caused by the app refreshing at all**:

- **Write-back failure (the friend's bug).** On machines where the `security` subprocess can't modify the Keychain item, the refreshed token is never saved. The Keychain keeps the now-dead refresh token, so Claude Code's (and the app's own) next refresh fails → "sign in to Claude Code again," and re-login only helps until the next refresh+restart. macOS Keychain ACLs are **process-tree dependent** — a `security` call that works from the user's shell can be silently denied when spawned by the GUI app (confirmed in the `fino` project's own notes), which is why the friend never saw a permission prompt.
- **Rotating-token race.** Even when write-back succeeds, if Claude Code already holds the prior refresh token in memory (or both refresh near-simultaneously), the second refresh presents a consumed token → logout.

PR #1 ("token-refresh-safety") and PR #2 ("credential-error-resilience") hardened and softened the refresh path but did not remove the root cause: **the app should never refresh.**

### Investigation findings (resolved)

- **Token rotation is real:** `performRefresh()` stores the server's new `refresh_token` (`Sources/ClaudeUsageCore/Credentials.swift:232`); each refresh kills the prior token.
- **The app has always refreshed:** commit `0699e0e` (first core commit) already had proactive near-expiry refresh + Keychain write-back; `3212a65` already retried on 401. There was never a read-only build — so every logout the user observed happened *with* refresh active. This refutes the hypothesis that refresh logic prevents logouts; it causes them.
- **Read-only is logout-proof:** reading the Keychain (`find-generic-password`) is non-mutating, and presenting an expired access token to `GET /api/oauth/usage` returns 401 **without** consuming the refresh token (only the token endpoint rotates it, and read-only never calls it). The sole residual vector — server-side revocation from repeatedly presenting a dead token — is designed out by never calling the usage API with an expired token (see U2/U4).
- **Access-token lifetime is on the order of hours** (observed ~4h+ remaining on a live token), so "stale when idle" is a benign degradation: usage doesn't change while idle anyway, and Claude Code refreshes the token the next time it's used.

---

## Goal / Success Criteria

1. The app **never** calls the OAuth token endpoint, **never** writes the Keychain, and **never** consumes the refresh token — verified by tests asserting `security add-generic-password` and the refresh URL are never invoked.
2. When the stored access token is valid, usage displays live as today.
3. When the stored token is expired/absent, the app shows **last-known usage** (persisted across restarts) with an "as of HH:MM — open Claude Code to refresh" hint, and does **not** call the usage API until a fresh token appears.
4. The app **auto-recovers**: once Claude Code refreshes its own token, the next poll resumes live usage with no user action.
5. Already-broken users recover with a **single** Claude Code re-login; the failure never recurs after this ships.

---

## Key Technical Decisions

- **Strictly read-only credential access.** Remove `refresh()`, `performRefresh()`, `persist()`, `forceRefreshAccessToken()`, the single-flight `inFlightRefresh`, the stdin write-back, and the write-back side of `cacheFreshest`. Keep `load()` (Keychain read + `~/.claude/.credentials.json` fallback), `decodeEnvelope`, and `isExpired`.
- **Gate API calls on token validity, not on refresh.** The app only calls the usage API when the stored access token is non-expired. An expired token means "Claude Code hasn't refreshed yet" → show stale, keep cheaply re-reading the Keychain each tick to detect recovery. This both avoids the revocation vector and yields automatic recovery without a separate back-off timer.
- **Treat a 401 as terminal-for-this-tick, never a refresh trigger.** No retry, no second request with a fresh token (there is no fresh token to mint).
- **Persisted last-known usage** in the app's own Application Support directory (a file the app can always write — unlike the shared Keychain item), so the rings show real data immediately on launch and during stale periods.
- **`refreshToken` stays in the decoded model but is never read** — minimizes churn to `ClaudeCredentials` while guaranteeing it's unused.

---

## Scope Boundaries

**In scope:** removing all refresh/write-back from `CredentialStore`; removing the 401-refresh retry from `UsageClient`; a small persisted last-usage store; AppState stale-mode + load-on-launch; updating affected tests; a brief README note on the read-only model + the one-time re-login for already-broken users.

### Deferred to Follow-Up Work
- A richer "stale" visual treatment for the menu bar icon/rings (e.g., dimmed rings while stale). This plan surfaces staleness via the popover hint and timestamp; iconography polish is separate.
- Detecting Keychain item *changes* via event subscription rather than poll-tick re-reads (the 60s re-read is sufficient and simpler).

### Non-goals
- Any independent token refresh or credential mutation by this app — explicitly removed and must not return.

---

## System-Wide Impact

- `UsageClient.fetchUsage()` error surface changes (no more refresh retry; new "token expired" classification). `AppState.describe`/error mapping must absorb it.
- The popover's "Refresh" button remains, but now re-reads + re-fetches read-only (no token mutation).
- `TokenProvider` protocol shrinks (drops `forceRefreshAccessToken`, redefines the read method). All conformers/fakes/tests update.

---

## Implementation Units

### U1. Make `CredentialStore` strictly read-only

**Goal:** The credential store only reads; it can never refresh, write the Keychain, or consume the refresh token.

**Requirements:** Success criteria 1, 4.

**Dependencies:** none.

**Files:**
- `Sources/ClaudeUsageCore/Credentials.swift` (modify)
- `Tests/ClaudeUsageCoreTests/CredentialsTests.swift` (modify)
- `Tests/ClaudeUsageCoreTests/CredentialErrorTests.swift` (modify)

**Approach:**
- Remove `refresh()`, `performRefresh()`, `persist()`, `forceRefreshAccessToken()`, `inFlightRefresh`, `RefreshResponse`, the refresh URL/clientID/scope constants, and the write-back semantics of `cacheFreshest` (a read-only store has no rotated token to prefer; an optional simple in-memory cache of the last successful read is acceptable but must never originate from a refresh).
- Redefine `TokenProvider` to a read-only shape returning the stored token plus whether it is currently usable, e.g. a `TokenSnapshot { accessToken: String; isExpired: Bool }` via a single `currentToken()` method. Drop `forceRefreshAccessToken`.
- Keep `load()` (Keychain read via `security find-generic-password`, then `~/.claude/.credentials.json` fallback), `decodeEnvelope`, and `isExpired`.
- Trim `CredentialError` to read-relevant cases: `notAuthenticated`, `commandFailed`, `commandTimedOut`, `decodingFailed`. Remove `refreshFailed`.
- Keep `runCommand` running `security` off the actor executor (read can still block/prompt), but it is now only ever used for `find-generic-password` (read).

**Patterns to follow:** existing actor + `runCommand` + `LocalizedError` conventions already in `Credentials.swift`.

**Test scenarios:**
- `currentToken()` returns the stored access token with `isExpired == false` for a non-expired stored credential.
- `currentToken()` returns the stored access token with `isExpired == true` for an expired stored credential (does not throw, does not refresh).
- No code path ever invokes `security add-generic-password` — assert the `FakeCommandRunner` records **zero** calls whose args contain `add-generic-password` across load + currentToken.
- No code path ever issues an HTTP request to the OAuth token endpoint — assert the `FakeTransport` is never called by `CredentialStore`.
- Missing Keychain item and missing fallback file → `currentToken()`/`load()` throws `notAuthenticated`.
- Keychain read fails but fallback file present → reads credentials from the fallback file.
- Corrupt Keychain JSON → `decodingFailed`.
- `CredentialErrorTests`: drop `refreshFailed`; every remaining case still has actionable, non-"error N" text.

---

### U2. Remove the 401-refresh retry from `UsageClient`; classify expired/401 without refreshing

**Goal:** `UsageClient` never refreshes and never calls the API with a known-expired token.

**Requirements:** Success criteria 1, 3, 4.

**Dependencies:** U1.

**Files:**
- `Sources/ClaudeUsageCore/UsageClient.swift` (modify)
- `Tests/ClaudeUsageCoreTests/UsageClientTests.swift` (modify)

**Approach:**
- `fetchUsage()` obtains `currentToken()`. If `isExpired` → throw a new `UsageError.tokenExpired` **without** sending any request.
- If not expired → send the request once. On 401 → throw `UsageError.unauthorized` (no retry, no `forceRefreshAccessToken`, no second request). On 2xx → decode. On other non-2xx → existing `UsageError.http`.
- Remove the `forceRefreshAccessToken` call site entirely.

**Patterns to follow:** existing `makeRequest`/error-classification structure in `UsageClient.swift`.

**Test scenarios:**
- Expired stored token → `fetchUsage()` throws `UsageError.tokenExpired` and the transport is **never** called (assert call count == 0).
- Valid token + 200 → returns decoded `ClaudeUsage`; transport called exactly once.
- Valid token + 401 → throws `UsageError.unauthorized`; transport called **exactly once** (no retry); token provider's read method called once and no refresh method exists/invoked.
- Valid token + 500 → `UsageError.http(status: 500, …)`.

---

### U3. Persisted last-known-usage store

**Goal:** Persist the most recent successful usage + timestamp to a file the app can always write, for display on launch and during stale periods.

**Requirements:** Success criteria 3.

**Dependencies:** none (can land in parallel with U1/U2).

**Files:**
- `Sources/ClaudeUsageCore/LastUsageStore.swift` (create)
- `Tests/ClaudeUsageCoreTests/LastUsageStoreTests.swift` (create)

**Approach:**
- Small type with `save(_ usage: ClaudeUsage, at: Date)` and `load() -> (usage: ClaudeUsage, date: Date)?`.
- Store as JSON at `~/Library/Application Support/<app dir>/last-usage.json`, created with owner-only permissions; directory created on demand. Path injectable for tests (mirror the `fallbackFileURL` injection pattern in `CredentialStore`).
- All failures are non-fatal: a missing or corrupt file yields `nil`; a failed write is logged (never the token — there are no tokens here) and ignored.

**Patterns to follow:** `Codable` + `JSONEncoder`/`JSONDecoder` usage already in `Credentials.swift`; injectable file URL like `CredentialStore.fallbackFileURL`.

**Test scenarios:**
- Round-trip: `save` then `load` returns equal usage and timestamp (within encoding precision).
- Missing file → `load()` returns `nil`.
- Corrupt/garbage file contents → `load()` returns `nil` (no throw).
- `save` to a directory that doesn't exist yet creates it and succeeds.

---

### U4. AppState stale-mode: load last usage on launch, persist on success, degrade gracefully on expiry

**Goal:** Show real data immediately and during stale periods; map expired/unauthorized/not-authenticated to a non-error "stale" state that retains usage and auto-recovers.

**Requirements:** Success criteria 2, 3, 4, 5.

**Dependencies:** U2, U3.

**Files:**
- `Sources/ClaudeUsageCore/AppState.swift` (modify)
- `Tests/ClaudeUsageCoreTests/AppStateTests.swift` (modify)

**Approach:**
- Inject a `LastUsageStore`. On init/`startPolling`, load persisted usage so the rings render last-known data immediately (phase reflects "stale until first live fetch" when the loaded data is older than the poll interval).
- On successful fetch → save to the store and set `.loaded`.
- Add a `.stale` phase (or a `stale` boolean alongside `.loaded`) used when `UsageError.tokenExpired`, `UsageError.unauthorized`, or `CredentialError.notAuthenticated` occurs: keep the existing `usage`, set a message like "Showing usage as of HH:MM — open Claude Code to refresh," do **not** clear data, do **not** treat as a hard error.
- Because U2 makes an expired token skip the API entirely, ordinary polling already avoids hammering the server; each 60s tick still cheaply re-reads the Keychain, so when Claude Code refreshes (token becomes valid) the next tick resumes live fetches automatically. No separate back-off timer needed.
- Genuine errors (HTTP 5xx, decoding, command failures) keep the existing fail-soft behavior (retain previous usage, show an error message).
- Update `AppState.describe` for the new and removed error cases.

**Patterns to follow:** existing `@MainActor` `ObservableObject` + fail-soft `refresh()` + `describe()` in `AppState.swift`.

**Test scenarios:**
- On launch with persisted usage present → `usage` is populated from the store before/independent of the first network call.
- Successful fetch → persists usage to the store (assert the injected store received a `save`).
- `UsageError.tokenExpired` → phase is `.stale` (not `.error`), previous/loaded `usage` retained, message contains "open Claude Code".
- `CredentialError.notAuthenticated` with no persisted usage → a clear "not signed in / open Claude Code" state, no crash, no refresh attempt.
- Recovery: expired tick (stale, no usage change) followed by a valid tick → returns to `.loaded` with fresh usage.
- Genuine `UsageError.http(500)` → existing fail-soft error behavior unchanged (previous usage retained, error message set).

---

## Risks & Mitigations

- **Risk: users already broken (dead refresh token in their Keychain) still see "sign in" until they re-login.** Mitigation: documented one-time recovery — run `claude` and re-login once; after this ships the app never consumes the token again, so it cannot recur. Note this in the README.
- **Risk: "stale when idle" perceived as the app being broken.** Mitigation: explicit "as of HH:MM — open Claude Code to refresh" hint + showing real last-known rings (not blank). Token lifetime is hours, so live data resumes as soon as Claude Code is used.
- **Risk: a revoked-but-not-yet-expired token still 401s.** Mitigation: handled as `.stale` (no refresh, no retry) and recovers when Claude Code refreshes; the app never escalates to a token mutation.
- **Risk: regression reintroducing refresh.** Mitigation: tests assert `add-generic-password` and the token endpoint are never invoked (U1/U2) — a guardrail against future reintroduction.

---

## Verification

- `swift build` and `swift test` green; new/updated tests cover U1–U4 scenarios.
- Grep guard: no remaining references to `add-generic-password`, `forceRefreshAccessToken`, `grant_type`, or the OAuth token URL in `Sources/`.
- Manual `--once` against a live valid token prints usage; against an expired token prints/exits indicating stale without attempting a refresh (no Keychain write, observable via no token mutation).
