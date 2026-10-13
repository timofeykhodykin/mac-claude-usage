import Foundation

/// Registers this app as Claude Code's status-line command in `~/.claude/settings.json`.
///
/// Only ever takes the slot when it is empty, already ours, or held by the old
/// `ClaudeUsageMiniBar --statusline` (whose readout we reproduce). Another tool's status line
/// is never overwritten. A backup of settings.json is written before the first change.
enum StatusLineInstaller {
    enum State: Equatable {
        case installed
        case notInstalled
        /// Another command owns the status line.
        case occupied(command: String)
    }

    /// Resolved through symlinks so a dotfiles-managed settings.json stays a symlink.
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
            .resolvingSymlinksInPath()
    }

    static var ourCommand: String? {
        Bundle.main.executablePath.map(command(forExecutable:))
    }

    /// Claude Code runs the status line through a shell. Inside double quotes the shell still
    /// expands `$`, backticks and `\`, so those (and `"`) are escaped: an app path can't run code.
    static func command(forExecutable path: String) -> String {
        let escaped = path.reduce(into: "") { result, character in
            if "\"\\$`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return "\"\(escaped)\" --statusline"
    }

    static func state() -> State {
        guard let command = currentCommand() else { return .notInstalled }
        if isOurs(command) { return .installed }
        if isReplaceable(command) { return .notInstalled }
        return .occupied(command: command)
    }

    /// Installs (or repoints after the app moved). Returns false if the slot belongs to someone else.
    @discardableResult
    static func install() throws -> Bool {
        guard let ourCommand else { return false }
        var root = try readSettings()
        let existing = (root["statusLine"] as? [String: Any])?["command"] as? String
        if let existing {
            if existing == ourCommand { return true }
            guard isOurs(existing) || isReplaceable(existing) else { return false }
        }
        root["statusLine"] = ["type": "command", "command": ourCommand]
        try writeSettings(root)
        return true
    }

    static func uninstall() throws {
        var root = try readSettings()
        guard let command = (root["statusLine"] as? [String: Any])?["command"] as? String,
              isOurs(command) else { return }
        root.removeValue(forKey: "statusLine")
        try writeSettings(root)
    }

    // MARK: - Helpers

    private static func currentCommand() -> String? {
        ((try? readSettings())?["statusLine"] as? [String: Any])?["command"] as? String
    }

    static func isOurs(_ command: String) -> Bool {
        command.contains("/MacClaudeUsage\"") && command.hasSuffix("--statusline")
    }

    /// The previous usage app's status line, which ours fully replaces.
    static func isReplaceable(_ command: String) -> Bool {
        command.contains("ClaudeUsageMiniBar") && command.hasSuffix("--statusline")
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private static func writeSettings(_ root: [String: Any]) throws {
        let fm = FileManager.default
        let backup = settingsURL.appendingPathExtension("before-mac-claude-usage")
        if fm.fileExists(atPath: settingsURL.path), !fm.fileExists(atPath: backup.path) {
            try fm.copyItem(at: settingsURL, to: backup)
        }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // An atomic write replaces the file with a new one at default permissions; settings.json
        // can hold API keys in `env`, so keep it as private as it was.
        let mode = (try? fm.attributesOfItem(atPath: settingsURL.path))?[.posixPermissions]
        try data.write(to: settingsURL, options: .atomic)
        if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: settingsURL.path) }
    }
}
