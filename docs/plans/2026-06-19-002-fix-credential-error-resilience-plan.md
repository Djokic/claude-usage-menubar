---
title: "fix: Resilient credential errors — non-fatal persist, in-memory cache, clear messages"
type: fix
status: active
created: 2026-06-19
depth: standard
---

# fix: Resilient credential errors — non-fatal persist, in-memory cache, clear messages

A user saw the menu bar show **"The operation couldn't be completed. (ClaudeUsageCore.CredentialError error 1.)"**. That's `CredentialError.commandFailed` surfacing raw. The app had already successfully refreshed the OAuth token (the network POST succeeded) but then failed to **write the rotated token back into the Keychain** via `security` — and that write failure was thrown all the way to the UI as a fatal, cryptic error. This plan makes that whole class of failure non-fatal and legible.

---

## Problem Frame

In `Sources/ClaudeUsageCore/Credentials.swift`, `performRefresh()` does: read current creds → POST to the refresh endpoint → build the rotated `ClaudeCredentials` → `try await persist(...)` → return. The `persist()` step shells out to `security add-generic-password` to write the new tokens back. On a machine where that write is denied (e.g. a copied/ad-hoc-signed app modifying an item another app created, or any non-zero `security` exit), `persist()` throws `commandFailed`, which propagates through `refresh()` → `validAccessToken()` → `fetchUsage()` → `AppState.refresh()`.

Two failures compound:

1. **Fatal when it shouldn't be.** The refresh already succeeded — the app holds a valid access token and *could* show usage. Instead the persist failure discards everything and shows an error. Worse, because the server rotated the refresh token but we couldn't save it, the stale Keychain token is now invalid, so retry/next-launch can loop or lock out.
2. **Cryptic.** `AppState.describe()` only special-cases `CredentialError.notAuthenticated`; every other `CredentialError` (`commandFailed`, `commandTimedOut`, `refreshFailed`, `decodingFailed`) falls through to `default: (error as NSError).localizedDescription`, which renders the useless "CredentialError error N".

This was the deferred P1 from the prior review (`docs/residual-review-findings/` / the token-refresh-safety PR) now hitting a real user.

---

## Requirements

- **R1** — A Keychain **write-back failure after a successful refresh is non-fatal**: the refreshed access token is returned and the UI shows usage; the persist failure is logged, not thrown.
- **R2** — An **in-memory credentials cache** holds the freshest known credentials so a failed persist doesn't cause cross-call breakage: `load()` returns the freshest of (Keychain, cache), falls back to the cache when the Keychain read fails, and the next refresh uses the freshest (cached, rotated) refresh token rather than the stale Keychain one.
- **R3** — **Every `CredentialError` has a clear, actionable message** (`LocalizedError`), and the UI never shows raw "CredentialError error N". Messages guide the user ("sign in to Claude Code", "allow Keychain access").
- **R4** — All credential/Keychain failure modes **degrade gracefully** with actionable text rather than a fatal generic error.

---

## Scope Boundaries

**In scope:** `CredentialStore` refresh/persist/load resilience + in-memory cache, `CredentialError` messaging, and `AppState.describe()` mapping, with tests.

### Deferred to Follow-Up Work
- Persisting a rotated token across app **restarts** when the Keychain write is permanently denied — inherently impossible without a working write; the in-memory cache only covers the running session. A future option is a private app-owned Keychain item as a secondary store (out of scope here).
- The usage **GET** request timeout (separately deferred in the prior plan).

### Out of Scope (Non-Goals)
- Changing the credential source (still Claude Code's Keychain item via `security`).
- Switching the write path to `SecItem*` (the CLI + double-stdin write already works where permitted; this plan handles the *denied* case gracefully rather than changing the mechanism).
- Any UI/ring/polling change beyond the error text shown in the popover.

---

## Key Technical Decisions

1. **Non-fatal persist.** `performRefresh()` wraps `persist()` in a do/catch: on failure it logs a warning (via `FileHandle.standardError` / `print` to stderr, matching the codebase's minimal logging) and continues, returning the freshly-refreshed credentials. The access token is valid regardless of whether it was saved, so the fetch must not fail.

2. **In-memory cache as the freshness authority.** `CredentialStore` (the actor) gains `private var cachedCredentials: ClaudeCredentials?`. It's updated whenever we obtain credentials (successful Keychain read or successful refresh). `load()` resolves to the **freshest** by `expiresAt`:
   - Keychain read succeeds → return `max(keychainCreds, cachedCredentials)` by `expiresAt`, and store that back as the cache. (Normal case: Keychain ≥ cache → Keychain wins, so external rotations by Claude Code are respected. Persist-failed case: cache > Keychain → cache wins, so our rotated token is used.)
   - Keychain read fails (`commandFailed`/`commandTimedOut`) → return the cache if present (graceful), else the existing file-fallback, else `notAuthenticated`.
   - `decodingFailed` from the Keychain blob still throws (real corruption), unchanged.
   This keeps single-flight refresh correct and means a persist failure never causes a re-refresh loop within a session.

3. **`CredentialError: LocalizedError`** with an `errorDescription` per case, e.g. not-authenticated → "Not signed in to Claude Code — open Claude Code and sign in"; commandFailed → "Couldn't read your Claude credentials from the Keychain — make sure Claude Code is installed and allow Keychain access if prompted"; commandTimedOut → "Keychain access timed out — try again"; refreshFailed → "Couldn't refresh your Claude session — sign in to Claude Code again"; decodingFailed → "Couldn't read the stored Claude credentials". Because `LocalizedError.errorDescription` bridges to `NSError.localizedDescription`, this alone removes the raw "error N" everywhere; `AppState.describe()` is also updated to map the key credential cases explicitly so the most actionable wording wins.

---

## Implementation Units

Dependency order: **U1** → **U2** (both touch `Credentials.swift`; U1 is the messaging layer, U2 the resilience logic).

### U1. Human-readable, actionable credential errors

**Goal:** No `CredentialError` ever reaches the user as "CredentialError error N"; each carries clear, actionable text.
**Requirements:** R3, R4.
**Dependencies:** none.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Sources/ClaudeUsageCore/AppState.swift`, `Tests/ClaudeUsageCoreTests/CredentialErrorTests.swift` (new), `Tests/ClaudeUsageCoreTests/AppStateTests.swift`.
**Approach:** Conform `CredentialError` to `LocalizedError`, implementing `errorDescription` for every case with the wording from Decision 3 (include the `security` exit status in the `commandFailed` text for diagnosis). Update `AppState.describe()` to map each `CredentialError` case to its actionable message (delegating to `errorDescription` is acceptable) and keep the existing `UsageError` cases. Ensure the `default` branch can no longer produce a raw enum description for a `CredentialError`.
**Patterns to follow:** existing `AppState.describe()` switch; existing `CredentialError` enum.
**Test scenarios:**
- Covers R3. Each `CredentialError` case (`notAuthenticated`, `commandFailed`, `commandTimedOut`, `refreshFailed`, `decodingFailed`) has a non-empty `errorDescription` that does **not** contain "error 1"/"CredentialError" and **does** contain actionable guidance (e.g. "Claude Code" / "Keychain").
- Covers R3. `AppState.describe(CredentialError.commandFailed(status:1,message:""))` returns a friendly message, not the raw NSError string.
- Covers R4. `AppState.describe()` for `refreshFailed`, `commandTimedOut`, `decodingFailed` each returns a distinct actionable message.
- Regression: `describe(UsageError.http(...))` and the existing `notAuthenticated` message are unchanged.

### U2. Non-fatal persist + in-memory credential cache

**Goal:** A failed Keychain write-back after a successful refresh never errors the UI, and the freshest credentials are always used within the session.
**Requirements:** R1, R2, R4.
**Dependencies:** U1.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Tests/ClaudeUsageCoreTests/CredentialsTests.swift`.
**Approach:** Add `private var cachedCredentials: ClaudeCredentials?` to the actor. In `performRefresh()`, after a successful POST, build the rotated creds, set the cache, then attempt `persist()` inside a do/catch — on failure log to stderr and proceed; return the rotated creds either way. Rework `load()` per Decision 2: on a successful Keychain read, return and cache the freshest of (Keychain, cache) by `expiresAt`; on a Keychain read failure, prefer the cache, then the file fallback, then `notAuthenticated`; keep `decodingFailed` throwing. A small private helper picks the freshest of two optional credentials.
**Patterns to follow:** existing `load()` catch structure, `isExpired` (uses `expiresAt`), the single-flight `refresh()`/`performRefresh()` split.
**Test scenarios:**
- Covers R1. Refresh succeeds (POST 200) but the persist runner throws → `refresh()` **returns** the rotated creds (does not throw) and `transport.requests.count == 1`.
- Covers R2. After a persist-failed refresh, `load()` returns the **rotated** creds (from cache), not the stale Keychain blob.
- Covers R2. `load()` when the Keychain creds are newer (higher `expiresAt`) than the cache → returns the Keychain creds (external rotation respected) and updates the cache.
- Covers R2/R4. `load()` when the Keychain read fails (runner throws) but a cache exists → returns the cache (graceful), no throw.
- Covers R4. `load()` when the Keychain read fails and there is no cache and no fallback file → throws `notAuthenticated` (unchanged).
- Covers R2. A second `refresh()` after a persist-failed first refresh uses the cached (rotated) refresh token in its POST body — assert the refresh request carries the rotated token, not the stale one.
- Regression: refresh + successful persist → returns rotated creds, persist invoked with the secret via stdin (existing behavior intact).
- `decodingFailed` from a malformed Keychain blob still throws and is not masked by the cache/fallback.

---

## System-Wide Impact

Contained to `CredentialStore` and `AppState.describe()`. The shared-Keychain touch point is unchanged in intent; the change makes a **denied write** survivable instead of fatal. `UsageClient`, the renderer, the status item, and the SwiftUI views are untouched (they consume `TokenProvider`/`UsageClient` and `AppState` through unchanged signatures). The only behavioral change users see: where they previously got a cryptic fatal error, they now see usage (when a refresh succeeded) or an actionable message (when it genuinely can't proceed).

---

## Risks & Mitigations

- **R-A — Cache masks an external rotation by Claude Code.** If our cache were always preferred, a token Claude Code rotated externally would be ignored. *Mitigation:* the freshest-by-`expiresAt` rule means the Keychain wins whenever it's newer-or-equal; the cache only wins when it is strictly newer (i.e. we rotated and couldn't persist).
- **R-B — Cross-restart staleness when persist is permanently denied.** The in-memory cache dies with the process; on relaunch we read the stale Keychain, and if our last rotation wasn't saved the refresh token is invalid → `refreshFailed`. *Mitigation:* this now surfaces as an actionable "sign in to Claude Code again" message (U1) rather than a loop or cryptic error; a durable secondary store is explicitly deferred.
- **R-C — Logging a secret.** The persist-failure log must not include token material. *Mitigation:* log only the error/status, never the credentials JSON; covered by review.

---

## Verification Strategy

- **Automated (`swift test`):** the per-unit scenarios above — error messaging for every `CredentialError` case and `describe()` mapping (U1); non-fatal persist, freshest-wins cache resolution, cache fallback on Keychain failure, and rotated-token reuse (U2). Existing tests (57) must stay green, with the persist-success regression confirming unchanged happy-path behavior.
- **Manual:** `./build.sh && ./ClaudeUsage.app/Contents/MacOS/ClaudeUsageApp --once` still prints live usage. Simulate a denied write (temporarily point the persist at a failing command, or revoke the Keychain item's modify ACL) and confirm `--once` / the popover shows usage with a logged warning instead of "CredentialError error 1".

---

## Deferred Implementation Notes

- Exact log sink (stderr `print` vs `FileHandle.standardError` vs `os_log`) — match whatever minimal logging the app already uses; decide during execution.
- Exact wording of each `errorDescription` — start from Decision 3 and refine for tone.
- Whether `describe()` should fully delegate to `LocalizedError.errorDescription` or keep an explicit switch — decide while implementing U1 (keep whichever is clearer and keeps the actionable wording).
