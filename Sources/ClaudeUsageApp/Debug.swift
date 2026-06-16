import AppKit
import SwiftUI
import ClaudeUsageCore

/// Returns fixed sample usage — used by the `--render-tooltip` headless verification path.
struct SampleUsageClient: UsageFetching {
    func fetchUsage() async throws -> ClaudeUsage {
        ClaudeUsage(
            fiveHour: UsageWindow(utilization: 19, resetsAt: Date().addingTimeInterval(3 * 3600 + 22 * 60)),
            sevenDay: UsageWindow(utilization: 63, resetsAt: Date().addingTimeInterval(2 * 86400 + 4 * 3600))
        )
    }
}

/// Run the real credential + usage-client pipeline once, print the result, and exit.
/// Exercises the full live path: Keychain → token → usage API → decode → formatting.
func fetchOnceAndExit() -> Never {
    Task { @MainActor in
        let store = CredentialStore()
        let client = UsageClient(tokenProvider: store)
        do {
            let usage = try await client.fetchUsage()
            let now = Date()
            if let five = usage.fiveHour {
                print("5h:  \(Int(five.utilization))% used — \(ResetFormatter.countdown(resetsAt: five.resetsAt, now: now))")
            }
            if let seven = usage.sevenDay {
                print("7d:  \(Int(seven.utilization))% used — \(ResetFormatter.countdown(resetsAt: seven.resetsAt, now: now))")
            }
            print("OK: live fetch + decode + format succeeded")
        } catch {
            print("FETCH FAILED: \(error)")
        }
        exit(0)
    }
    RunLoop.main.run()
    fatalError("run loop exited unexpectedly")
}

/// Render `TooltipView` (with sample data) to a PNG, then exit. Drives the main actor by
/// spinning the run loop, so async refresh + the @MainActor ImageRenderer both work without UI.
func renderTooltipSampleAndExit(to path: String) -> Never {
    _ = NSApplication.shared  // initialize AppKit so SF Symbols resolve in the snapshot
    Task { @MainActor in
        let state = AppState(client: SampleUsageClient())
        await state.refresh()

        let renderer = ImageRenderer(content: TooltipView(state: state))
        renderer.scale = 2
        if let image = renderer.nsImage, let data = RingIconRenderer.png(for: image) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("Wrote tooltip sample to \(path)")
        } else {
            print("Failed to render tooltip sample")
        }
        exit(0)
    }
    RunLoop.main.run()
    // RunLoop.main.run() does not return under normal use; exit(0) above terminates the
    // process once the render completes. fatalError keeps the Never return type honest.
    fatalError("run loop exited unexpectedly")
}
