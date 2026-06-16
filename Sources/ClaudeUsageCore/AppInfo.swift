import Foundation

/// Static app-level constants shared across the core library.
public enum AppInfo {
    /// User-agent sent with usage requests. Mirrors the Claude Code CLI value (see the
    /// `fino` `claude-cli` client) because the OAuth usage endpoint is undocumented and
    /// the agent string is part of the de-facto contract. Bump only if the endpoint
    /// starts rejecting it.
    public static let userAgent = "claude-code/2.0.67"
}
