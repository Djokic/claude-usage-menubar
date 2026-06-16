import AppKit
import SwiftUI
import ClaudeUsageCore

// Single home for converting the core library's platform-agnostic RGBAColor into the
// two platform color types the app uses (NSColor for Core Graphics drawing, SwiftUI
// Color for the popover). Keeps the conversion logic from drifting across files.

extension NSColor {
    convenience init(_ c: RGBAColor) {
        self.init(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
