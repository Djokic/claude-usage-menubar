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

See `docs/plans/` for the full implementation plan.

## Limitations

- Uses an **undocumented** Claude OAuth usage endpoint; it may change without notice.
- The app is ad-hoc signed; distributing it to other machines would need code signing /
  notarization (out of scope).
- Launch-at-login, a preferences window, and per-model breakdown rows are deferred follow-ups.
