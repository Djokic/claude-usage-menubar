# Claude Usage Menubar

A tiny macOS menu bar app that shows your Claude subscription usage as two Apple-Watch-style
activity rings:

- **Outer ring** — 5-hour session limit
- **Inner ring** — 7-day weekly limit

Hover the icon for a popover with a progress bar and reset countdown for each limit, plus a
manual refresh button. Usage auto-refreshes every 60 seconds.

It reads your **local Claude Code credentials** from the macOS Keychain and queries the same
Claude OAuth usage endpoint the Claude Code CLI uses — no API key or extra sign-in required.

## Requirements

- macOS 13 (Ventura) or later
- Swift toolchain (Command Line Tools is enough — full Xcode not required)
- You must be signed in to **Claude Code** on this machine (the app reuses its Keychain
  credentials, Keychain item `Claude Code-credentials`)

## Build & run

```sh
./build.sh           # builds release + assembles ClaudeUsage.app
open ClaudeUsage.app  # launch (appears in the menu bar, no Dock icon)
```

To see logs while developing, run the binary directly:

```sh
./ClaudeUsage.app/Contents/MacOS/ClaudeUsageApp
```

The first time the app reads the Keychain, macOS will ask you to allow access to the
`Claude Code-credentials` item — click **Allow** (or **Always Allow**).

## Usage

The app lives entirely in the menu bar (no Dock icon, no window):

- **Hover** the rings → a popover shows each limit's progress bar, percent used, and reset
  countdown, plus a refresh button. Moving the pointer into the popover keeps it open.
- **Click** the icon → pins the popover open (so the refresh button is easy to hit). Click
  again to dismiss.
- **Right-click** the icon → **Refresh now** / **Quit Claude Usage**.
- Usage refreshes automatically every 60 seconds; the refresh button forces an immediate update.

## Appearance

- **Two rings:** outer = the 5-hour session limit, inner = the 7-day weekly limit. The arc
  length shows how much of each limit is used; a wider gap keeps the two rings distinct.
- **Menu bar icon** is a monochrome template image while both limits are under 75% — it adapts
  to the menu bar like Apple's own icons (white in dark mode, black in light mode).
- **Color alerts:** a ring turns **orange at ≥75%** and **red at ≥90%** so an approaching limit
  reads at a glance, even in the menu bar.
- **Tooltip** progress bars use blue normally, with the same orange/red escalation.

## Tests

```sh
swift test
```

Unit tests cover the testable core: usage JSON decoding, credential/expiry/refresh logic,
the usage API client (request shape + 401-retry), reset-time formatting, ring geometry, and
app-state polling/refresh transitions.

## Troubleshooting

Run the binary directly to use the built-in debug flags:

```sh
BIN=./ClaudeUsage.app/Contents/MacOS/ClaudeUsageApp
$BIN --once             # run the real fetch pipeline once and print usage (verifies auth)
$BIN --render-samples /tmp/rings   # write sample ring icons as PNGs
$BIN --render-tooltip /tmp/tip.png # render the tooltip popover to a PNG
```

If `--once` prints `FETCH FAILED`, make sure you're signed in to Claude Code (`claude`),
then allow Keychain access when macOS prompts.

## How it works

| Piece | What it does |
|-------|--------------|
| `ClaudeUsageCore` | Pure, unit-tested logic: models, Keychain credentials + token refresh, usage client, formatting, ring geometry, app state. |
| `ClaudeUsageApp`  | AppKit/SwiftUI shell: dual-ring `NSImage` renderer, `NSStatusItem` with hover/click popover + right-click menu, SwiftUI tooltip. |

See `docs/plans/` for the full implementation plan, and
`docs/residual-review-findings/` for known follow-up work surfaced by code review (a few
reliability/security hardening items worth doing before heavy use).

## Distribution

This is a personal/power-user tool, best shared as a **directly distributed** app:

- **Local use (today):** `build.sh` ad-hoc signs the bundle, so it runs on this machine.
  Copying it to another Mac triggers a Gatekeeper warning until it's properly signed.
- **Sharing it:** sign with a **Developer ID** certificate and **notarize** it (requires an
  Apple Developer Program membership), then ship as a `.dmg`/`.zip`. No sandbox needed, so it
  can keep reading the Keychain and shelling out to `security`.
- **Mac App Store: not feasible as built.** App Store apps must run in the **App Sandbox**,
  which cannot read another app's Keychain item (`Claude Code-credentials`) or spawn the
  `/usr/bin/security` subprocess. The app also relies on an **undocumented Anthropic endpoint
  and the Claude Code OAuth client**, which App Review prohibits (private API use,
  impersonation, trademark). A store-eligible version would need an official third-party usage
  API, its own OAuth sign-in, full sandboxing, and Anthropic's blessing for the branding.

## Limitations

- Uses an **undocumented** Claude OAuth usage endpoint; it may change or break without notice.
- Reuses Claude Code's Keychain credentials (and refreshes the shared OAuth token), so it
  depends on Claude Code being installed and signed in.
- Launch-at-login, a preferences window, and per-model breakdown rows are deferred follow-ups.
