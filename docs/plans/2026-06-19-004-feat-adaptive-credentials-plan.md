---
title: "feat: Adaptive credentials — write-gated refresh with first-launch probe"
type: feat
status: active
created: 2026-06-19
depth: deep
---

# feat: Adaptive credentials — write-gated refresh with first-launch probe

## Problem Frame

The app shares one Keychain item (`Claude Code-credentials`) with the Claude Code CLI, holding a **single-use, rotating** OAuth refresh token. PR #3 made credential handling strictly read-only to stop the app from consuming that token and logging Claude Code out. That works but sacrifices live data: once the access token expires during idle, the rings go stale until Claude Code is next used.

The reference tool `~/Projects/fino/shared/lib/claude-cli/auth.ts` shows refresh *can* work reliably: it re-reads fresh credentials before refreshing, writes the rotated token back to the Keychain (keeping Claude Code in sync), and **never hard-errors** — on any refresh failure it falls back to the current access token. fino works because (a) the Keychain write-back succeeds on the user's machine, and (b) it degrades instead of erroring.

The logout only happens when a refresh **consumes** the token but the **write-back fails** (leaving a dead token in the Keychain) — and macOS Keychain *modify* ACLs are process-tree dependent, so a `security` write spawned by a GUI app can be denied where the same command works from the user's shell. PR #1's switch from argv to stdin write-back, plus surfacing failures as errors, is what broke us where fino doesn't.

**This plan makes credential handling adaptive:** refresh (live data) only on machines where we can prove the Keychain write-back works; everywhere else, fall back to PR #3's read-only behavior. The capability is decided by a one-time write-access probe on first launch.

---

## Goal / Success Criteria

1. **First launch prompts once for write access** by re-saving the exact current credential bytes back to the Keychain (a true no-op), surfacing the macOS "allow modify" prompt. The result is persisted so it never re-prompts.
2. **Write granted → refresh mode:** near-expiry tokens are refreshed, written back (Claude Code stays in sync), and used. Refresh/write failures never hard-error — they fall back to the current token, then to stale.
3. **Write denied → read-only mode:** never refresh, and **never send a known-expired token to the usage API** — show last-known usage + "open Claude Code to refresh" and recover when Claude Code refreshes its own token.
4. **No regression of the read-only guarantees** on write-denied machines: nothing is consumed, nothing is logged out.
5. **Tokens never appear in argv or logs** — all Keychain writes feed the secret via stdin.

---

## Key Technical Decisions

- **Write-access is a persisted, probed capability.** A `WriteAccessStore` (UserDefaults-backed, injectable) holds `Bool?` (`nil` = not yet probed). `CredentialStore.ensureWriteAccessProbed()` probes once when the stored value is `nil`: read the raw Keychain bytes, write them **verbatim** back via `security add-generic-password -U` (stdin), and persist the success/failure. A real write-back failure during refresh later downgrades the flag to `false` for the session.
- **The probe is a true no-op.** It writes back the *exact bytes read* (not a re-encoded value), so the stored credentials are never altered — only the item's modify-ACL gains `/usr/bin/security` if the user approves.
- **Adaptivity lives in `currentToken()`.** Read credentials; if valid, return them. If expired: **if write is granted**, attempt refresh (re-read fresh → POST → write back); on any failure fall back to returning the current (expired) snapshot. **If write is denied**, return the expired snapshot without refreshing. The caller (`UsageClient`) already turns an expired snapshot into `.tokenExpired` (→ stale, no API call), so the "never query an expired token" rule holds in every branch.
- **Keep PR #3's read-only scaffolding** — `TokenSnapshot`, `UsageClient`'s expired/401 handling, `AppState.stale`, and `LastUsageStore` — unchanged. This plan *adds* a write/refresh path behind the gate; it does not rewrite the read path.
- **Re-introduce, behind the gate, what PR #3's review removed:** `CommandRunner` stdin support, `ClaudeCredentials.refreshToken`, the refresh POST + `RefreshResponse`, single-flight, and stdin `persist`. These return because the adaptive design genuinely needs to write — but only fire when write access is proven.
- **fino's resilience, adopted:** re-read fresh before refreshing (shrinks the rotating-token race); never hard-error (fall back to current token, then stale).

---

## High-Level Technical Design

Decision flow for `currentToken()` (directional guidance, not implementation spec):

```
read credentials (Keychain → fallback file)
│
├─ not expired ─────────────────────────────► return {token, isExpired:false}
│
└─ expired
   ├─ write GRANTED:
   │    re-read fresh → POST refresh → persist(new)        ─ success ─► return {new token, isExpired:false}
   │    └─ POST fails OR persist fails (downgrade grant)   ─ fail ────► return {current token, isExpired:true}
   │
   └─ write DENIED:                                                     return {current token, isExpired:true}

UsageClient: isExpired:true → throw .tokenExpired (no request) → AppState .stale (show last-known, watch Keychain)
```

First-launch probe (runs once, at app start, before/with the first poll):

```
ensureWriteAccessProbed():
  if WriteAccessStore.granted != nil: load it, return        (no write, no prompt)
  raw = read raw Keychain bytes
  try: write raw back verbatim (stdin)  → granted = true     (macOS prompts here, first time)
  catch:                                  granted = false
  WriteAccessStore.granted = granted
```

---

## Scope Boundaries

**In scope:** `WriteAccessStore`; the first-launch probe; write-gated refresh + stdin write-back (re-introduced); adaptive `currentToken()`; launch wiring of the probe; tests; README update covering the adaptive behavior.

### Deferred to Follow-Up Work
- Re-probing/upgrading from denied → granted later in a session (e.g. if the user changes Keychain ACLs). For now `denied` persists until the stored flag is cleared; a future "Recheck access" menu item could re-probe.
- A user-visible indicator of which mode (refresh vs read-only) the app is in.

### Non-goals
- Querying the usage API with a known-expired token (forbidden in every mode).
- Any refresh when write access is not proven.

---

## System-Wide Impact

- `CredentialStore` regains write/refresh surface (and a `transport` + `WriteAccessStore` dependency) — `AppDelegate` and `Debug.swift` wiring update, and the probe must be triggered at launch.
- `CommandRunner`/`ProcessCommandRunner`/`FakeCommandRunner` regain stdin (reverting part of PR #3's review cleanup) — `Transport.swift`, `Fakes.swift`, `CommandRunnerTests` update.
- `UsageClient` and `AppState.stale`/`LastUsageStore` are unchanged in contract; the expired→stale path now also covers "refresh failed" and "write denied."

---

## Implementation Units

### U1. `WriteAccessStore` — persisted write-grant flag

**Goal:** Persist whether the Keychain write-back is allowed on this machine, so the probe runs at most once.

**Requirements:** Success criteria 1.

**Dependencies:** none.

**Files:**
- `Sources/ClaudeUsageCore/WriteAccessStore.swift` (create)
- `Tests/ClaudeUsageCoreTests/WriteAccessStoreTests.swift` (create)

**Approach:**
- Small type wrapping `UserDefaults` (suite/key injectable for tests) exposing `granted: Bool?` get/set, where `nil` means "not yet probed." Mirror the injection style of `LastUsageStore`/`CredentialStore.fallbackFileURL`.
- Sendable; safe to hand to the `CredentialStore` actor.

**Patterns to follow:** `LastUsageStore` (injectable persistence), `CredentialStore` init dependency injection.

**Test scenarios:**
- Default (unset key) → `granted == nil`.
- Set `true` then read back → `true`; set `false` → `false`.
- Two instances over the same suite/key observe each other's writes (persistence).

---

### U2. Re-introduce Keychain write + first-launch write-access probe

**Goal:** Give `CredentialStore` the ability to write the Keychain again (stdin, no argv), and a one-time probe that proves whether that write works on this machine.

**Requirements:** Success criteria 1, 5.

**Dependencies:** U1.

**Files:**
- `Sources/ClaudeUsageCore/Transport.swift` (modify — re-add stdin to `CommandRunner`/`ProcessCommandRunner`)
- `Sources/ClaudeUsageCore/Credentials.swift` (modify — raw read helper, `persist`, `probeWriteAccess`/`ensureWriteAccessProbed`)
- `Tests/ClaudeUsageCoreTests/Fakes.swift` (modify — `FakeCommandRunner` records stdin again)
- `Tests/ClaudeUsageCoreTests/CommandRunnerTests.swift` (modify — restore stdin coverage)
- `Tests/ClaudeUsageCoreTests/CredentialsTests.swift` (modify)

**Approach:**
- Re-add the `stdin: String?` parameter to `CommandRunner.run` and the `ProcessCommandRunner` stdin pipe (the secret is fed over stdin, never argv — the `main.swift` SIGPIPE ignore already covers the pipe write).
- Add a raw-read helper that returns the exact Keychain string (the existing `load()` decodes; the probe needs the raw bytes). Reuse it for both decode and verbatim write-back.
- Re-add `persist(_ credentials)` (stdin double-feed for the password + retype prompts), and `probeWriteAccess()` that reads raw bytes and writes them back **verbatim** via `add-generic-password -U`.
- `ensureWriteAccessProbed()`: if `WriteAccessStore.granted != nil`, adopt it; else probe once and persist the result. Idempotent.

**Patterns to follow:** the pre-PR#3 `persist`/`runCommand` (git history `0699e0e`/`64505d0`) for the stdin write; off-executor `runCommand` for the blocking subprocess.

**Test scenarios:**
- Probe success (runner returns OK for `add-generic-password`) → `granted` persisted `true`.
- Probe failure (runner throws `commandFailed` on `add-generic-password`) → `granted` persisted `false`, and the probe itself does **not** throw.
- The probe feeds the **exact raw bytes read** to the write command's stdin (assert recorded stdin contains the verbatim read value — no re-encoding).
- `ensureWriteAccessProbed()` performs **no** write when `WriteAccessStore.granted` is already set (assert no `add-generic-password` call).
- Secret travels via stdin, never argv (assert the token never appears in recorded arguments).
- `CommandRunnerTests`: stdin delivered to the child process again; zero-exit/non-zero-exit/timeout paths still pass.

---

### U3. Re-introduce write-gated token refresh

**Goal:** Restore the OAuth refresh exchange + rotated-token write-back, single-flight and off-executor, non-fatal on persist failure.

**Requirements:** Success criteria 2.

**Dependencies:** U2.

**Files:**
- `Sources/ClaudeUsageCore/Credentials.swift` (modify)
- `Tests/ClaudeUsageCoreTests/CredentialsTests.swift` (modify)

**Approach:**
- Re-add `ClaudeCredentials.refreshToken` (needed to exchange), the refresh URL/clientID/scope constants, `RefreshResponse`, and a `transport: HTTPTransport` dependency on `CredentialStore`.
- `refresh()`: re-read **fresh** credentials (so a token Claude Code already rotated is used), POST the `refresh_token` grant, build new credentials (expiry = now + `expires_in`), `persist` them. Single-flight via an in-flight `Task`, cleared in the task's own `defer`. Persist failure is **non-fatal** — log (never the token) and return the refreshed creds; downgrade `WriteAccessStore.granted` to `false` so we stop refreshing this session.
- Hold the refreshed creds in memory so a failed write-back still yields a usable token for the current session.

**Patterns to follow:** pre-PR#3 `refresh`/`performRefresh`/single-flight (git `0699e0e`/`6d2fdd9`) and the non-fatal persist from the credential-error-resilience work.

**Test scenarios:**
- Refresh POSTs the correct body (grant_type, refresh_token from the freshly-read creds, client_id, scope) to the token endpoint.
- Refresh computes expiry from `expires_in` and persists the rotated token (stdin carries the new secret; argv does not).
- Concurrent refreshes coalesce into a single POST (single-flight); a later refresh after completion starts a new POST.
- Persist failure after a successful POST is **non-fatal** — `refresh()` returns the rotated creds and downgrades the write-grant flag to `false`.
- A failed POST propagates (so `currentToken` can fall back) and leaves single-flight retryable.

---

### U4. Adaptive `currentToken()` — gate refresh on write access

**Goal:** Refresh only when write is granted; otherwise behave read-only. Never return a non-expired snapshot built from an expired token.

**Requirements:** Success criteria 2, 3, 4.

**Dependencies:** U3.

**Files:**
- `Sources/ClaudeUsageCore/Credentials.swift` (modify)
- `Tests/ClaudeUsageCoreTests/CredentialsTests.swift` (modify)

**Approach:**
- `currentToken()`: load creds; if not expired → return `{token, isExpired:false}`. If expired and **write granted** → `try refresh()`; on success return `{new token, isExpired:false}`; on failure return `{current token, isExpired:true}`. If expired and **write denied** → return `{current token, isExpired:true}` with no refresh attempt.
- Resolve `canWrite` from the probed/persisted flag (adopt `WriteAccessStore.granted`, defaulting to read-only when still `nil`).

**Test scenarios:**
- Valid token → returns `isExpired:false`, performs **no** refresh (no POST, no write).
- Expired + granted → refreshes, returns the fresh token with `isExpired:false`; one POST.
- Expired + granted + refresh POST fails → returns the current token with `isExpired:true` (caller will stall to stale), no crash.
- Expired + **denied** → returns `isExpired:true` and performs **no** POST and **no** `add-generic-password` (assert both) — the read-only guarantee.
- After a refresh whose persist failed, the grant flag is `false`, so the next expiry does not attempt another refresh.

---

### U5. Wire the first-launch probe; confirm stale path end-to-end

**Goal:** Trigger the write-access probe once at app start (surfacing the prompt on first launch), and confirm the adaptive store flows through `UsageClient`/`AppState` unchanged.

**Requirements:** Success criteria 1, 3.

**Dependencies:** U2, U4.

**Files:**
- `Sources/ClaudeUsageApp/AppDelegate.swift` (modify — construct `CredentialStore` with `transport` + `WriteAccessStore`, trigger `ensureWriteAccessProbed()` at launch)
- `Sources/ClaudeUsageApp/Debug.swift` (modify — `--once` path constructs the store the same way; probe optional there)
- `README.md` (modify — adaptive behavior + one-time re-login note)
- `Tests/ClaudeUsageCoreTests/AppStateTests.swift` (modify if AppState gains any probe hook; otherwise unchanged)

**Approach:**
- In `AppDelegate.applicationDidFinishLaunching`, build `CredentialStore(transport:..., writeAccessStore:...)`, fire `Task { await store.ensureWriteAccessProbed() }` before/with `state.startPolling()` so the macOS prompt appears at first launch.
- Keep `UsageClient` and `AppState.stale` as-is: an expired snapshot still becomes `.tokenExpired` → stale, which now also covers the write-denied and refresh-failed cases.
- README: document the two modes, the one-time write prompt, and that already-broken users need a single Claude Code re-login.

**Test scenarios:**
- `Test expectation: none` for the AppKit wiring itself (no behavioral logic beyond construction + a one-shot probe call); covered by U2/U4 unit tests for the probe and adaptive logic.
- If a probe hook is added to `AppState`, assert it calls `ensureWriteAccessProbed()` exactly once on `startPolling`.

---

## Risks & Mitigations

- **Risk: the probe write itself logs Claude Code out** (if it somehow alters the item). Mitigation: write back the *exact bytes read*, a true no-op; verify in manual/integration that reading the item after the probe returns the original value.
- **Risk: refresh consumes the token but write-back fails on a machine we mis-detected as writable.** Mitigation: persist failure is non-fatal AND downgrades the grant to `false`; the rotated token stays usable in memory for the session, and we stop refreshing. Cross-restart, the user gets one re-login (documented) — same as today.
- **Risk: stale `expiresAt` right after re-auth makes read-only mode show stale even though the token works** (fino tries it anyway). Mitigation: accepted per the "never query an expired token" rule; resolves when Claude Code next writes a corrected expiry. Noted as a known minor edge.
- **Risk: re-introducing write machinery re-introduces the argv-leak hazard.** Mitigation: all writes feed the secret via stdin; tests assert the token never appears in argv.

---

## Verification

- `swift build` + `swift test` green; new/updated tests cover U1–U4 scenarios.
- Grep: writes go through stdin; no token in argv; no usage-API call on an expired token (the `.tokenExpired` guard remains).
- Manual: on a write-capable machine, `--once` after expiry refreshes and the Keychain item's token rotates while Claude Code stays logged in; on a write-denied machine, the app shows stale without consuming the token.
