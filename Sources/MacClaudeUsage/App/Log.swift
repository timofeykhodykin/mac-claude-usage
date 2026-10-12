import os

/// View with: `log stream --predicate 'subsystem == "dev.mac-claude-usage"' --info`
/// Never log tokens — only outcomes.
enum Log {
    static let auth = Logger(subsystem: "dev.mac-claude-usage", category: "auth")
    static let usage = Logger(subsystem: "dev.mac-claude-usage", category: "usage")
}
