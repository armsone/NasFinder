import Foundation

enum RemoteFileVisibilityPolicy {
    /// Dot-prefixed entries are remote system/configuration files by default.
    /// Keep this policy separate from the browser so a future “show hidden
    /// files” preference can replace it without changing every layout.
    static func shouldDisplay(filename: String) -> Bool {
        !filename.hasPrefix(".")
    }
}
