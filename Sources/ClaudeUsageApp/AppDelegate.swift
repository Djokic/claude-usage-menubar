import AppKit
import ClaudeUsageCore

/// Composes the app on launch: Keychain-backed credentials → usage client → app state →
/// status item controller, then starts the 60-second poll. Missing credentials don't crash;
/// the icon shows empty rings and the popover explains how to sign in (handled by AppState /
/// TooltipView via the fail-soft refresh path).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let credentialStore = CredentialStore()
            let usageClient = UsageClient(tokenProvider: credentialStore)
            let state = AppState(client: usageClient)
            let controller = StatusItemController(state: state)

            self.state = state
            self.controller = controller

            state.startPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            state?.stop()
        }
    }
}
