import AppKit
import Foundation

// Ignore SIGPIPE so writing a secret to a subprocess (the `security` CLI) whose read end has
// already closed fails the syscall as EPIPE (caught locally) instead of terminating the app.
signal(SIGPIPE, SIG_IGN)

// Headless verification path: render sample ring icons to PNGs and exit (no UI).
if let index = CommandLine.arguments.firstIndex(of: "--render-samples") {
    let path = CommandLine.arguments.indices.contains(index + 1)
        ? CommandLine.arguments[index + 1]
        : NSTemporaryDirectory()
    let dir = URL(fileURLWithPath: path, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try RingIconRenderer.writeSamples(to: dir)
        print("Wrote ring samples to \(dir.path)")
        exit(0)
    } catch {
        print("Failed to write ring samples: \(error)")
        exit(1)
    }
}

// Headless verification path: render the tooltip popover (with sample data) to a PNG and exit.
if let index = CommandLine.arguments.firstIndex(of: "--render-tooltip") {
    let path = CommandLine.arguments.indices.contains(index + 1)
        ? CommandLine.arguments[index + 1]
        : FileManager.default.temporaryDirectory.appendingPathComponent("tooltip.png").path
    renderTooltipSampleAndExit(to: path)
}

// Headless verification path: run the real fetch pipeline once and print the result.
if CommandLine.arguments.contains("--once") {
    fetchOnceAndExit()
}

// Menu bar agent: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
