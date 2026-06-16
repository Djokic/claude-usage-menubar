---
title: "feat: Claude usage menu bar app with dual activity rings"
type: feat
status: completed
created: 2026-06-16
depth: standard
---

# feat: Claude usage menu bar app with dual activity rings

A macOS menu bar agent that renders the user's Claude subscription usage as two concentric Apple-Watch-style rings (outer = 5-hour session limit, inner = 7-day weekly limit). Hovering the icon reveals a popover with a horizontal progress bar and reset countdown for each limit, plus a manual refresh button. Usage is fetched every 60 seconds from the same undocumented Claude OAuth usage endpoint the `~/Projects/fino` `claude-cli` client uses, authenticated with the local Claude Code keychain credentials.

---

## Problem Frame

The user wants an always-visible, glanceable view of how much of their Claude subscription budget they have consumed, without opening claude.ai. The menu bar is the natural surface: a tiny ring icon communicates both limits at a glance, and a hover popover gives the exact numbers and reset times — mirroring the "Plan usage limits" panel on the Claude website (provided reference screenshot: "Current session … Resets in 2 hr 36 min … 19% used" and weekly "All models … Resets Tue 1:00 PM").

The data source and authentication technique are already proven in `~/Projects/fino` (`shared/lib/claude-cli/usage.ts` + `auth.ts`). This plan reimplements that technique natively in Swift and wraps it in a menu bar UI. **`fino` is the authoritative reference for the API contract** — its exact endpoint, headers, credential location, and response shape are carried into the decisions below verbatim.

---

## Scope & Requirements

Requirements derived from the request (used for traceability in implementation units):

- **R1** — Runs as a macOS menu bar agent in the top-right status area, with no Dock icon and no main window.
- **R2** — The status icon is two concentric Apple-Watch-style rings: **outer ring = 5-hour limit**, **inner ring = 7-day limit**, each filling proportionally to utilization.
- **R3** — Hovering the icon shows a popover ("tooltip").
- **R4** — The popover shows the **5-hour limit** as a horizontal progress-bar line plus reset time formatted like `3h 22min (17:52)`.
- **R5** — The popover shows the **7-day limit** the same way (reset for a multi-day window shown as a day/time, e.g. `Tue 13:00`).
- **R6** — Usage is fetched using the **local Claude credentials** (macOS Keychain) against the Claude OAuth usage API, per the `fino` `claude-cli` client.
- **R7** — Usage auto-refreshes **every 60 seconds**.
- **R8** — The popover has a **manual refresh button**, like the Claude website.

---

## Scope Boundaries

**In scope:**
- Dual-ring menu bar icon (R1, R2), hover popover with two progress rows + reset times + refresh button (R3–R5, R8).
- Keychain-backed credential loading and OAuth token refresh; usage fetch (R6).
- 60-second auto-poll + manual refresh (R7, R8).
- A right-click context menu with **Refresh** and **Quit** (a menu-bar-only app otherwise has no way to quit — this is a usability necessity, not scope creep).
- Graceful handling of missing/expired credentials and endpoint failures (fail-soft: keep last good data, show a stale/error indicator).
- SwiftPM build + a script that assembles a runnable `.app` bundle.

### Deferred to Follow-Up Work
- **Launch at Login** (`SMAppService`) — commonly wanted for a menu bar utility but not requested; ship core first.
- Preferences window (configurable poll interval, ring colors, 12h/24h clock).
- First-class breakdown rows for `seven_day_opus` / `seven_day_sonnet` / `extra_usage`. We will **opportunistically render** these extra weekly windows when the API returns them non-null, but they are not a required deliverable and need no dedicated polish.
- Code signing / notarization / DMG packaging for distribution.
- Near-limit notifications and historical usage graphs.

### Out of Scope (Non-Goals)
- Modifying Claude Code itself or its credential management.
- A raw Anthropic API-key mode (this app is for subscription usage via OAuth credentials only).
- Windows/Linux support (macOS menu bar app).

---

## Key Technical Decisions

1. **AppKit `NSStatusItem` + `NSPopover`, with SwiftUI popover content — not SwiftUI `MenuBarExtra`.** `MenuBarExtra` opens on *click only* and cannot show on hover (R3), and the icon must be a custom-drawn dual-ring `NSImage`. So the shell is AppKit; the popover's content view is a SwiftUI `TooltipView` hosted via `NSHostingController`.

2. **Build with Swift Package Manager (`swift build`), not Xcode.** The machine has only Command Line Tools (`xcodebuild` is unavailable; verified). A `build.sh` script assembles the `.app` bundle (binary → `Contents/MacOS/`, `Info.plist` → `Contents/`) and ad-hoc code-signs it (`codesign --sign -`) for keychain-ACL stability and to avoid "damaged app" Gatekeeper warnings. The app sets `NSApp.setActivationPolicy(.accessory)` in code *and* declares `LSUIElement` in `Info.plist` (belt and suspenders) so it runs as a menu bar agent (R1).

3. **Library/executable split for testability.** Pure logic (models, decoding, credential/expiry math, API request building, formatting, ring geometry) lives in a `ClaudeUsageCore` library target; AppKit/SwiftUI glue lives in the `ClaudeUsageApp` executable target. Tests run against `ClaudeUsageCore` via `swift test` (which works under CLT). AppKit/SwiftUI UI glue is verified manually.

4. **Credentials via the `security` CLI reading service `Claude Code-credentials`** (faithful to `fino`, proven to work). The secret is a JSON blob `{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" } }` (`expiresAt` is epoch **milliseconds**). A first-run Keychain access prompt is expected for any non-Claude-Code reader. Fallback: read `~/.claude/.credentials.json` if the Keychain read fails and the file exists.

5. **Token refresh persists rotated tokens back to the Keychain.** Refresh is `POST https://console.anthropic.com/v1/oauth/token` with `{ grant_type: "refresh_token", refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e", scope: "user:profile user:inference user:sessions:claude_code" }`. Anthropic rotates refresh tokens (the response returns a *new* `refresh_token`), so the new credentials **must** be written back via `security add-generic-password -U -a "claude-cli" -s "Claude Code-credentials" -w '<json>'` or the next refresh fails. Refresh only when within a 5-minute buffer of `expiresAt`, and **re-read the Keychain immediately before refreshing** so tokens Claude Code already rotated are picked up (mitigates shared-credential races).

6. **Usage endpoint contract (verbatim from `fino`):** `GET https://api.anthropic.com/api/oauth/usage`, headers `accept: application/json`, `anthropic-beta: oauth-2025-04-20`, `authorization: Bearer <accessToken>`, `content-type: application/json`, `user-agent: claude-code/2.0.67`. No body. Response is decoded into `ClaudeUsage` (see U2). On HTTP 401, refresh the token once and retry.

7. **Ring mapping & rendering.** Outer ring ← `five_hour.utilization`, inner ring ← `seven_day.utilization` (both 0–100). Each ring is a faint background track plus a colored progress arc starting at 12 o'clock, sweeping **clockwise**, with rounded line caps (Apple-Watch look). Distinct base colors per ring (default: outer/5h = Claude clay `#D97757`, inner/7d = blue `#4A7DFF`), with an optional warning tint toward red as a ring approaches 100%. The icon is a **non-template colored** `NSImage` (color is what distinguishes the two rings; vivid arcs read fine in both light and dark menu bars), rendered at @2x for Retina.

8. **Hover/click UX model.** Hover over the status button shows the popover (R3); a short grace delay before closing prevents flicker when the cursor moves from the button into the popover, and the popover counts as "still hovering". A click **pins** the popover open (so the refresh button is comfortably clickable); right-click opens the context menu (Refresh, Quit). Hover for status items is finicky (see Risks) — pin-on-click is the robustness fallback.

9. **Poll cadence.** `Timer` every 60 s (R7) with tolerance set for power efficiency; an immediate fetch on launch; manual refresh (R8) triggers an immediate fetch and resets the timer.

10. **Reset-time formatting.** For a window resetting in **< 24h**: `3h 22min (17:52)` (relative + absolute local clock). For **≥ 24h** (the 7-day window): show day-of-week + time, e.g. `Tue 13:00`, optionally prefixed with coarse relative (`2d 4h`). Absolute times follow the system locale (the example `17:52` implies a 24-hour clock).

---

## Output Structure

```text
claude-usage-menubar/
├── Package.swift                      # SwiftPM: app executable + core library + test target
├── README.md                          # build/run instructions, what it reads, limitations
├── build.sh                           # swift build -c release → assemble + ad-hoc sign ClaudeUsage.app
├── .gitignore                         # .build/, *.app, .DS_Store
├── Resources/
│   └── Info.plist                     # LSUIElement=true, bundle id, name, version
├── Sources/
│   ├── ClaudeUsageCore/               # pure, unit-tested logic
│   │   ├── Models.swift               # ClaudeUsage, UsageWindow, ExtraUsage
│   │   ├── Credentials.swift          # ClaudeCredentials, CredentialStore, refresh
│   │   ├── UsageClient.swift          # GET /api/oauth/usage (+ 401 refresh/retry)
│   │   ├── Formatting.swift           # reset-countdown text
│   │   └── RingGeometry.swift         # utilization→sweep angle, clamping, ring colors
│   └── ClaudeUsageApp/                # AppKit + SwiftUI glue (executable)
│       ├── main.swift                 # NSApplication bootstrap (.accessory)
│       ├── AppDelegate.swift          # wires AppState + StatusItemController
│       ├── AppState.swift             # ObservableObject: usage/loading/error + 60s poller
│       ├── RingIconRenderer.swift     # draws dual-ring NSImage
│       ├── StatusItemController.swift # NSStatusItem + hover/click popover + right-click menu
│       └── TooltipView.swift          # SwiftUI popover content
└── Tests/
    └── ClaudeUsageCoreTests/
        ├── ModelsTests.swift
        ├── CredentialsTests.swift
        ├── UsageClientTests.swift
        ├── FormattingTests.swift
        └── RingGeometryTests.swift
```

The tree is a scope declaration of the expected shape; per-unit `Files` lists are authoritative.

---

## High-Level Technical Design

*This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```text
                  every 60s / manual refresh
                            │
                            ▼
   ┌──────────────┐   ┌───────────────┐   ┌────────────────────────────┐
   │ AppState     │──▶│ UsageClient   │──▶│ GET api.anthropic.com       │
   │ (Observable) │   │  .fetchUsage()│   │   /api/oauth/usage          │
   └──────┬───────┘   └──────┬────────┘   └────────────┬───────────────┘
          │                  │  on 401                  │
          │                  ▼                          ▼
          │            ┌───────────────┐         ClaudeUsage JSON
          │            │ CredentialStore│        { five_hour, seven_day, … }
          │            │  Keychain R/W  │
          │            │  + token refresh│
          │            └───────────────┘
          │ @Published usage / error / lastUpdated
          ├───────────────────────────────┬───────────────────────────┐
          ▼                                ▼                           ▼
  RingIconRenderer                 StatusItemController          TooltipView (SwiftUI)
  (NSImage: 2 rings)  ──icon──▶   NSStatusItem.button  ──hover──▶ NSPopover content
                                  click=pin / right-click=menu    (2 progress rows,
                                                                   reset times, refresh)
```

Data flow: `AppState` owns the timer and the latest `ClaudeUsage`. On each tick it calls `UsageClient`, which pulls a valid access token from `CredentialStore` (refreshing if near expiry), hits the usage endpoint, and decodes the response. `AppState` publishes the result; `StatusItemController` redraws the ring icon via `RingIconRenderer`, and the SwiftUI `TooltipView` reflects the same state when the popover is open.

---

## Implementation Units

Dependency order: **U1** → (U2, U3, U5) → U4 → (U6, U7) → (U8, U9) → U10.

```text
U1 scaffolding ─┬─ U2 models ──────┬─ U4 client ─┬─ U7 state ─┬─ U8 status/popover ─┐
                ├─ U3 credentials ──┘             │            │                     ├─ U10 wire-up
                └─ U5 format/geometry ─┬─ U6 renderer ─────────┘                     │
                                       └─ U9 tooltip view ──────────────────────────┘
```

### U1. Project scaffolding & build pipeline

**Goal:** A SwiftPM package that builds a runnable menu-bar `.app` showing an empty/placeholder status item, plus a local git repo.
**Requirements:** R1 (foundation).
**Dependencies:** none.
**Files:** `Package.swift`, `Resources/Info.plist`, `build.sh`, `.gitignore`, `README.md`, `Sources/ClaudeUsageApp/main.swift` (minimal `.accessory` bootstrap + placeholder `NSStatusItem` showing a static glyph), `Sources/ClaudeUsageCore/` (empty placeholder so the library target compiles).
**Approach:**
- `Package.swift`: platform `.macOS(.v13)`; executable target `ClaudeUsageApp` (depends on `ClaudeUsageCore`), library target `ClaudeUsageCore`, test target `ClaudeUsageCoreTests`.
- `Info.plist`: `LSUIElement=true`, `CFBundleIdentifier` (stable, e.g. `com.stefan.ClaudeUsageMenubar` — stability matters for the Keychain ACL), name, short version, build version.
- `build.sh`: `swift build -c release`, then assemble `ClaudeUsage.app/Contents/{MacOS,Resources}`, copy binary + `Info.plist`, then `codesign --force --sign - ClaudeUsage.app` (ad-hoc).
- `main.swift`: `NSApplication.shared`, `setActivationPolicy(.accessory)`, create a placeholder `NSStatusItem` so launch is verifiable, `app.run()`.
- `git init` + initial commit (the directory is not yet a git repo; downstream pipeline steps need one).
**Patterns to follow:** standard SwiftPM executable layout; conventional macOS agent `Info.plist`.
**Test scenarios:** Test expectation: none — scaffolding. **Verification:** `swift build -c release` succeeds; `./build.sh` produces `ClaudeUsage.app`; launching it shows a status item and no Dock icon.

### U2. Usage data models & JSON decoding (Core)

**Goal:** `Codable` models that decode the real `/api/oauth/usage` response, including null windows.
**Requirements:** R6.
**Dependencies:** U1.
**Files:** `Sources/ClaudeUsageCore/Models.swift`, `Tests/ClaudeUsageCoreTests/ModelsTests.swift`.
**Approach:** Mirror the `fino` shape exactly:
- `UsageWindow { utilization: Double; resetsAt: Date }` decoded from `{ "utilization": Number(0–100), "resets_at": ISO8601 String }` (use `.convertFromSnakeCase` or explicit `CodingKeys`; decode `resets_at` with an ISO8601 strategy).
- `ExtraUsage { isEnabled: Bool; monthlyLimit: Double?; usedCredits: Double?; utilization: Double? }`.
- `ClaudeUsage { fiveHour: UsageWindow?; sevenDay: UsageWindow?; sevenDayOauthApps: UsageWindow?; sevenDayOpus: UsageWindow?; sevenDaySonnet: UsageWindow?; extraUsage: ExtraUsage? }`. Ignore the obfuscated `iguana_necktie` field (do not model it).
- All windows optional (the API returns `null` for inactive windows).
**Patterns to follow:** `fino` `shared/lib/claude-cli/usage.ts` interfaces (`UsageWindow`, `ClaudeUsage`, `ExtraUsage`).
**Test scenarios:**
- Covers R6. Decodes a full payload (both `five_hour` and `seven_day` present) → correct utilization values and parsed `resets_at` dates.
- Decodes a payload with `five_hour` present but `seven_day` and all other windows `null` → optionals are nil, no throw.
- Decodes a payload with `seven_day_opus`/`seven_day_sonnet`/`extra_usage` present → mapped correctly.
- ISO8601 `resets_at` with `Z` suffix parses to the correct `Date`.
- Malformed JSON (utilization as string / missing required key in a present window) → throws a decoding error.
- Unknown extra field present (`iguana_necktie`) → ignored, decode still succeeds.

### U3. Keychain credential loading + token refresh (Core)

**Goal:** Load Claude OAuth credentials from the Keychain, detect near-expiry, refresh, and persist rotated tokens.
**Requirements:** R6.
**Dependencies:** U1.
**Files:** `Sources/ClaudeUsageCore/Credentials.swift`, `Tests/ClaudeUsageCoreTests/CredentialsTests.swift`.
**Approach:**
- `ClaudeCredentials { accessToken: String; refreshToken: String; expiresAt: Int }` decoded from the Keychain blob `{ "claudeAiOauth": { "accessToken", "refreshToken", "expiresAt" } }` (`expiresAt` = epoch ms).
- `CredentialStore`:
  - `load()` — run `security find-generic-password -s "Claude Code-credentials" -w` via `Process`, trim, decode JSON. On failure, fall back to reading `~/.claude/.credentials.json` if it exists.
  - `isExpired(now:)` — true when `now >= expiresAt - 5min` (buffer).
  - `refresh()` — re-read Keychain first, then `POST https://console.anthropic.com/v1/oauth/token` with the body from Decision 5; decode `{ access_token, refresh_token, expires_in }`; compute new `expiresAt = now + expires_in*1000`; persist via `security add-generic-password -U -a "claude-cli" -s "Claude Code-credentials" -w '<json>'` (single-quote-escape the JSON).
  - `validAccessToken()` — load; if expired, refresh and return the new token, else return the current token. Never throw solely because refresh failed if a usable (possibly stale) access token exists — let the caller's 401 path decide.
- Inject the subprocess runner (a `(String) throws -> String`-style closure) and the HTTP transport so tests don't touch the real Keychain or network.
**Patterns to follow:** `fino` `shared/lib/claude-cli/auth.ts` (`getCredentials`, `refreshToken`, `saveCredentials`, 5-minute buffer, in-memory cache, mutex).
**Test scenarios:**
- Decodes a Keychain blob string into `ClaudeCredentials` (accessToken/refreshToken/expiresAt correct).
- `isExpired`: token expiring in 10 min → not expired; expiring in 2 min → expired (within buffer); already past → expired.
- Covers R6. `refresh()` builds the correct POST body (grant_type, refresh_token, client_id, scope) — assert via injected transport.
- Refresh response parses into new credentials with `expiresAt = now + expires_in*1000`.
- After refresh, the persist command is invoked with `-U -a "claude-cli" -s "Claude Code-credentials"` and JSON containing the *new* refresh token (rotation persisted).
- Keychain read fails AND no fallback file → `load()` throws a clear "not authenticated" error.
- Keychain read fails AND `~/.claude/.credentials.json` exists → falls back and decodes it.
- JSON with single quotes/special chars in the secret is escaped correctly for the persist command.

### U4. Usage API client (Core)

**Goal:** Fetch and decode usage from the OAuth endpoint, with one token-refresh retry on 401.
**Requirements:** R6.
**Dependencies:** U2, U3.
**Files:** `Sources/ClaudeUsageCore/UsageClient.swift`, `Tests/ClaudeUsageCoreTests/UsageClientTests.swift`.
**Approach:**
- `UsageClient.fetchUsage() async throws -> ClaudeUsage`: get a valid token from `CredentialStore`, build a `GET` to `https://api.anthropic.com/api/oauth/usage` with the exact headers from Decision 6, run via injected `URLSession` (or a transport protocol), decode `ClaudeUsage` from U2.
- On HTTP 401: call `CredentialStore.refresh()` once, rebuild the request with the new token, retry once. A second 401 → throw an auth error.
- Non-2xx (other) → throw an error including status + truncated body. Network failure → propagate.
- Use a `URLProtocol` stub or injected transport for tests (no live network).
**Patterns to follow:** `fino` `shared/lib/claude-cli/usage.ts` `getUsage()` (exact headers, error message format `Usage API failed (status): body`).
**Test scenarios:**
- Covers R6. Request is a GET to the exact URL with all five required headers (Authorization Bearer, anthropic-beta `oauth-2025-04-20`, accept, content-type, user-agent).
- 200 with a valid body → returns decoded `ClaudeUsage` with expected utilizations.
- 401 once then 200 → triggers exactly one refresh and one retry, returns the second response.
- 401 twice → throws an auth error and does not loop indefinitely (refresh attempted once).
- 500 / non-2xx → throws an error carrying the status code.
- Transport throws (offline) → error propagates.

### U5. Display formatting & ring geometry (Core)

**Goal:** Pure functions for reset-countdown text and ring arc geometry/colors.
**Requirements:** R2, R4, R5.
**Dependencies:** U1 (uses `UsageWindow`/`Date` from U2 where convenient).
**Files:** `Sources/ClaudeUsageCore/Formatting.swift`, `Sources/ClaudeUsageCore/RingGeometry.swift`, `Tests/ClaudeUsageCoreTests/FormattingTests.swift`, `Tests/ClaudeUsageCoreTests/RingGeometryTests.swift`.
**Approach:**
- `resetCountdownText(resetsAt: Date, now: Date, calendar:locale:) -> String`:
  - < 24h: `"3h 22min (17:52)"` — relative `Xh Ymin` (omit `h` when < 1h: `22min`) plus absolute local time in parentheses.
  - ≥ 24h: `"Tue 13:00"` (abbreviated weekday + time), optionally prefixed with coarse `"2d 4h "`.
  - Already past / ≤ 0: `"now"` / `"Resetting…"`.
- `RingGeometry`:
  - `sweepFraction(utilization: Double) -> Double` = `clamp(utilization, 0, 100) / 100` (values > 100 clamp to a full ring).
  - `progressEndAngle(fraction:)` for a 12-o'clock start, clockwise sweep (in the renderer's angle convention).
  - `ringColor(base: RingColor, utilization: Double) -> RingColor` — returns the base color, tinting toward red past a warning threshold (e.g. ≥ 90%).
**Patterns to follow:** none specific; keep deterministic and timezone/locale-injectable for testing.
**Test scenarios:**
- Covers R4. `resetsAt` 3h22m ahead at 14:30 → `"3h 22min (17:52)"` (24h clock).
- < 1h ahead (e.g. 22 min) → `"22min (HH:mm)"` (no hours component).
- < 1 min ahead → `"now"` / resetting wording.
- Covers R5. `resetsAt` 2d4h ahead on a Tuesday → contains `"Tue 13:00"` (and coarse `2d 4h` if included).
- `resetsAt` in the past → past/now wording, never negative numbers.
- `sweepFraction`: 0 → 0; 50 → 0.5; 100 → 1.0; 137 → 1.0 (clamped); negative → 0.
- Covers R2. `progressEndAngle` for fraction 0.25 is a quarter sweep clockwise from 12 o'clock.
- `ringColor`: 40% → base color; 95% → warning/red tint.

### U6. Ring icon renderer (App)

**Goal:** Render the dual-ring status-bar `NSImage` from two utilization values.
**Requirements:** R2.
**Dependencies:** U5.
**Files:** `Sources/ClaudeUsageApp/RingIconRenderer.swift`.
**Approach:**
- `render(fiveHour: Double, sevenDay: Double, size: CGFloat) -> NSImage`: draw into an `NSImage` (lock focus or `NSImage(size:flipped:drawingHandler:)`), @2x scale for Retina.
- Outer ring (5h) and inner ring (7d): each draws a low-alpha background track (full circle) then a colored progress arc using `RingGeometry.sweepFraction` and `progressEndAngle`, starting at 12 o'clock, clockwise, with `lineCapStyle = .round`.
- Use distinct base colors (Decision 7) and the warning tint from `RingGeometry.ringColor`. Set `image.isTemplate = false` (colored icon).
- Size the icon to the status bar (~18 pt logical), with appropriate ring widths and inter-ring gap.
- Handle the missing-data state (nil utilization) by drawing only the dim tracks (a neutral "no data" look).
**Patterns to follow:** `RingGeometry` (U5) for all angle/color math — the renderer only draws.
**Test scenarios:** Test expectation: none (Core Graphics pixel drawing is verified visually). Optional lightweight check: `render(...)` returns a non-nil `NSImage` of the requested size with `isTemplate == false`. **Verification:** at 0/50/100% the rings visibly fill the expected fractions; both rings distinguishable in light and dark menu bars.

### U7. App state, polling, and refresh coordination (App)

**Goal:** Observable state that drives the icon and popover, with 60s auto-refresh and manual refresh.
**Requirements:** R7, R8.
**Dependencies:** U4, U2, U5.
**Files:** `Sources/ClaudeUsageApp/AppState.swift`.
**Approach:**
- `AppState: ObservableObject` with `@Published` `usage: ClaudeUsage?`, `phase` (`.idle/.loading/.loaded/.error`), `lastUpdated: Date?`, `errorMessage: String?`.
- `refresh()` (async): set `.loading` (preserve last good `usage` for fail-soft display), call `UsageClient.fetchUsage()`, update `usage` + `lastUpdated` on success or `errorMessage` on failure (keep stale `usage`).
- `startPolling()`: immediate fetch on launch, then a 60s `Timer` (with tolerance). `manualRefresh()` cancels/restarts the timer and fetches now (R8). Ensure published updates land on the main actor.
- Inject `UsageClient` (protocol) so tests use a stub.
**Patterns to follow:** standard `ObservableObject` + injected dependency.
**Test scenarios:**
- Covers R8. `refresh()` success path: phase goes `.loading` → `.loaded`, `usage` and `lastUpdated` set.
- `refresh()` failure path: phase → `.error`, `errorMessage` set, previous `usage` retained (fail-soft).
- Covers R7. Polling schedules a 60s repeat and performs an immediate initial fetch (assert via injected clock/timer or fetch-count from the stub client).
- `manualRefresh()` triggers an immediate fetch and resets the auto-poll timer.
- Concurrent/overlapping refresh requests don't corrupt state (a refresh in flight + a manual refresh resolves to a consistent final state).

### U8. Status item + hover/click popover controller (App)

**Goal:** The `NSStatusItem` with the ring icon, hover-driven popover, click-to-pin, and a right-click menu.
**Requirements:** R1, R2, R3, R8.
**Dependencies:** U6, U7, U9.
**Files:** `Sources/ClaudeUsageApp/StatusItemController.swift`.
**Approach:**
- Create `NSStatusItem` (variable length); set `button.image` to the rendered ring icon and refresh it whenever `AppState` publishes (Combine subscription).
- Hover: add an `NSTrackingArea` (`[.mouseEnteredAndExited, .activeAlways]`) to the status button. `mouseEntered` → show `NSPopover` anchored to the button; `mouseExited` → start a short grace timer that closes the popover only if the cursor is over neither the button nor the popover. Treat cursor-over-popover as "still hovering."
- Click: toggle a `pinned` flag that keeps the popover open regardless of hover (so the refresh button is comfortably clickable); a second click / outside dismissal unpins.
- Right-click (or `NSStatusBarButton` secondary action): show an `NSMenu` with **Refresh** (→ `AppState.manualRefresh()`) and **Quit** (`NSApp.terminate`).
- Popover `contentViewController = NSHostingController(rootView: TooltipView(state:))`; behavior `.transient` when not pinned.
**Patterns to follow:** conventional `NSStatusItem` + `NSPopover` + `NSTrackingArea` menu-bar app pattern.
**Test scenarios:** Test expectation: none (AppKit, event/timer-driven UI — verified manually). If a pure helper for the "should close after grace?" decision (cursor-in-button-or-popover) is extracted, unit-test it. **Verification:** hover shows the popover; moving into the popover keeps it open; leaving both closes it after the grace delay; click pins it open; right-click shows Refresh/Quit; the icon updates when usage changes.

### U9. Tooltip popover SwiftUI view (App)

**Goal:** The popover content: header with refresh + last-updated, and a progress row for each limit.
**Requirements:** R4, R5, R8.
**Dependencies:** U7, U5.
**Files:** `Sources/ClaudeUsageApp/TooltipView.swift`.
**Approach:**
- Header: title (e.g. "Claude usage"), a refresh button (circular-arrow `Image(systemName: "arrow.clockwise")`) that calls `state.manualRefresh()` and shows a spinner while `phase == .loading`, and a subtle "Updated 12s ago" line.
- **Current session (5h)** row: label, horizontal progress bar bound to `five_hour.utilization`, `"NN% used"`, and `"Resets in " + resetCountdownText(...)` (U5).
- **Weekly (7d)** row: same, bound to `seven_day.utilization`, reset shown in the ≥24h format.
- Optional rows for `seven_day_opus` / `seven_day_sonnet` / `extra_usage` rendered only when non-null (Deferred-scope nicety; cheap to include).
- States: `.loading` (first load, no data) → progress placeholder; `.error` → message + "Retry" wired to refresh; missing credentials → "Open Claude Code to sign in" guidance.
- Match the reference screenshot's plain, calm layout (label left, bar center, "% used" right).
**Patterns to follow:** SwiftUI `ProgressView`/custom bar; reference screenshot layout. All displayed text comes from U5 formatters (already tested).
**Test scenarios:** Test expectation: none (SwiftUI view — verified visually; underlying formatting tested in U5). **Verification:** with live data, both rows show correct %, bar fill, and reset text; refresh button shows a spinner then updates; error and no-credentials states render their guidance.

### U10. App wire-up & lifecycle

**Goal:** Boot the app end-to-end and handle the credentials-missing path gracefully.
**Requirements:** R1, R6, R7.
**Dependencies:** U7, U8.
**Files:** `Sources/ClaudeUsageApp/AppDelegate.swift`, `Sources/ClaudeUsageApp/main.swift` (finalize from U1 placeholder).
**Approach:**
- `main.swift`: `NSApplication.shared`, set delegate, `setActivationPolicy(.accessory)`, `run()`.
- `AppDelegate.applicationDidFinishLaunching`: build `AppState` (with a real `UsageClient` + `CredentialStore`), build `StatusItemController(state:)`, call `state.startPolling()`.
- Missing/invalid credentials at launch: don't crash — icon shows the dim "no data" rings (U6) and the popover explains how to authenticate (U9 error state).
**Patterns to follow:** standard AppKit `NSApplicationDelegate` bootstrap.
**Test scenarios:** Test expectation: none (integration/lifecycle — verified manually). **Verification:** launch via `./build.sh && open ClaudeUsage.app` → rings reflect real account usage within seconds; hover shows the populated popover; refresh updates it; the icon refreshes automatically about once a minute; quitting via the right-click menu removes the status item.

---

## System-Wide Impact

This is a new standalone app with **one** external touch point: it reads — and, on token refresh, **rewrites** — the shared `Claude Code-credentials` Keychain item that Claude Code itself owns. That shared write is the only place this app affects another system, and it is mitigated in Decision 5 / Risk R3 (re-read before refresh, refresh only near expiry, persist rotated tokens atomically). No databases, services, or other apps are affected.

---

## Risks & Mitigations

- **R1 — Hover popovers on status items are finicky.** Tracking-area boundaries, cursor transitions between button and popover, and focus quirks cause flicker or premature dismissal. *Mitigation:* grace-delay close that treats cursor-over-popover as still-hovering; **click-to-pin** as the robust fallback; a manual test matrix covering enter/leave/move-into-popover/click.
- **R2 — Undocumented endpoint & pinned headers.** `/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`, and the `claude-code/<version>` user-agent are unofficial and may change or be rejected. *Mitigation:* robust error handling, fail-soft UI (keep last good data, show a stale/error indicator), and keep the endpoint/headers/user-agent as easily editable constants in one place.
- **R3 — Shared-credential token-rotation races with Claude Code.** Both processes hold the same rotating refresh token; a refresh by one invalidates the other's. *Mitigation:* re-read the Keychain immediately before refreshing, refresh only within the 5-min expiry buffer (rare, since access tokens are long-lived relative to the 60s poll), persist atomically, and never block usage display on a refresh failure.
- **R4 — Keychain ACL prompt.** A non-Claude-Code reader triggers a macOS access prompt; an unstable bundle id / unsigned rebuilds can re-prompt. *Mitigation:* document the expected first-run prompt in the README; keep a **stable bundle identifier**; ad-hoc code-sign in `build.sh`; fall back to `~/.claude/.credentials.json` when present.
- **R5 — No Xcode / unsigned app.** Only CLT is installed; the assembled `.app` is ad-hoc signed, so Gatekeeper may warn on first open and distribution is out of scope. *Mitigation:* documented run instructions (`open ClaudeUsage.app`); signing/notarization deferred.
- **R6 — No git remote yet.** The pipeline's push/PR steps need a remote that doesn't exist. *Mitigation:* `git init` + local commits in U1; surface clearly at push/PR time that a GitHub remote must be configured before a PR can be opened.

---

## Verification Strategy

- **Automated (`swift test`):** Core logic — model decoding (U2), credential/expiry/refresh logic (U3), API request building and 401-retry (U4), reset-time formatting and ring geometry (U5), and AppState transitions/polling (U7) — covered by the per-unit test scenarios above using injected transports/clocks (no live network or Keychain).
- **Manual:** Build with `./build.sh`, `open ClaudeUsage.app`, and confirm against real account usage: rings fill correctly (compare to claude.ai "Plan usage limits"), hover popover matches the reference layout with correct %/reset text, manual refresh works, the icon auto-updates ~every 60s, error/no-credentials states render, and Quit works. The first-run Keychain prompt appears once and is granted.

---

## Deferred Implementation Notes

Resolve during execution, not now:
- Exact ring dimensions (status-bar icon point size, ring stroke widths, inter-ring gap) — tune visually against the real menu bar.
- Final color hex values and the warning-threshold percentage — start from Decision 7 defaults and adjust.
- Whether the 7-day reset line prefixes coarse relative time (`2d 4h`) or shows only the absolute `Tue 13:00` — decide against the real reset cadence and reference screenshot.
- The precise `user-agent` version string — start from `claude-code/2.0.67` (per `fino`); bump only if the endpoint rejects it.
- Exact mechanism for routing right-click vs left-click on the status button (secondary-action vs `NSMenu` attach) — pick whatever proves reliable during U8.
