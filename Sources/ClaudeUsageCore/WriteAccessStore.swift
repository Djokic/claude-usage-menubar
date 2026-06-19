import Foundation

/// Persists whether this machine grants the app write access to the shared `Claude Code-credentials`
/// Keychain item. `nil` means "not yet probed"; `true`/`false` is the remembered result of the
/// first-launch write-access probe (see `CredentialStore.ensureWriteAccessProbed`). Persisting it
/// means the macOS modify prompt only ever appears once.
///
/// UserDefaults is thread-safe, so this is safe to hand to the `CredentialStore` actor.
public final class WriteAccessStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ClaudeUsage.keychainWriteGranted") {
        self.defaults = defaults
        self.key = key
    }

    /// `nil` until the probe has run; thereafter the remembered grant result.
    public var granted: Bool? {
        get { defaults.object(forKey: key) as? Bool }
        set {
            if let newValue {
                defaults.set(newValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
