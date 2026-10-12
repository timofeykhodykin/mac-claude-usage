import Foundation

enum KeychainError: Error, LocalizedError {
    case notFound
    case badData
    case toolFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials in the Keychain. Run `claude` and sign in."
        case .badData:
            return "Claude Code's Keychain item has an unexpected format."
        case .toolFailed(let status, let message):
            return "Keychain access failed (security exited \(status)). \(message)"
        }
    }
}

/// Reads and writes Claude Code's own credential item ("Claude Code-credentials").
///
/// All access goes through Apple's `/usr/bin/security` tool, exactly like Claude Code does.
/// Claude Code creates the item through that tool, so the tool is on the item's ACL and
/// reads/writes happen silently — no "wants to access the keychain" prompts, and no ACL
/// changes that could break Claude Code's own access.
struct ClaudeKeychain: Sendable {
    static let securityTool = "/usr/bin/security"
    /// `security -i` rejects longer command lines; Claude Code falls back to argv above this.
    private static let interactiveLineLimit = 4032

    let service: String
    let account: String

    init(service: String = ClaudeKeychain.claudeCodeService(),
         account: String = ClaudeKeychain.claudeCodeAccount()) {
        self.service = service
        self.account = account
    }

    /// Mirrors Claude Code: `Claude Code-credentials`, plus a hash suffix of the config dir
    /// when `CLAUDE_CONFIG_DIR` is set (GUI apps normally don't see that variable).
    static func claudeCodeService() -> String {
        "Claude Code-credentials"
    }

    /// Mirrors Claude Code: `$USER`, falling back to a fixed name when it has odd characters.
    static func claudeCodeAccount() -> String {
        let user = ProcessInfo.processInfo.environment["USER"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(allowed.contains) else {
            return "claude-code-user"
        }
        return user
    }

    /// Returns the raw JSON blob stored in the item.
    func read() throws -> Data {
        var result = try ProcessRunner.run(Self.securityTool,
                                           ["find-generic-password", "-a", account, "-s", service, "-w"])
        if result.status == 44 {
            // Account mismatch (e.g. $USER differs) — fall back to matching by service only.
            result = try ProcessRunner.run(Self.securityTool,
                                           ["find-generic-password", "-s", service, "-w"])
        }
        switch result.status {
        case 0:
            return try Self.decodePassword(result.stdout)
        case 44:
            throw KeychainError.notFound
        default:
            throw KeychainError.toolFailed(status: result.status, message: result.stderrText)
        }
    }

    /// Replaces the item's secret with `json`, the same way Claude Code writes it.
    func write(_ json: Data) throws {
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let result: ProcessResult
        if line.utf8.count <= Self.interactiveLineLimit {
            // Via stdin so the secret never appears in the process list.
            result = try ProcessRunner.run(Self.securityTool, ["-i"], input: Data(line.utf8))
        } else {
            result = try ProcessRunner.run(Self.securityTool,
                                           ["add-generic-password", "-U", "-a", account,
                                            "-s", service, "-X", hex])
        }
        guard result.status == 0, !result.timedOut else {
            throw KeychainError.toolFailed(status: result.status, message: result.stderrText)
        }
    }

    /// `security -w` prints the secret as text, or as hex when it contains non-printable bytes.
    static func decodePassword(_ output: Data) throws -> Data {
        var data = output
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { throw KeychainError.badData }
        if data.first == UInt8(ascii: "{") { return data }
        guard let text = String(data: data, encoding: .ascii), let decoded = Data(hex: text),
              decoded.first == UInt8(ascii: "{") else {
            throw KeychainError.badData
        }
        return decoded
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = Self.nibble(chars[index]), let lo = Self.nibble(chars[index + 1]) else {
                return nil
            }
            bytes.append(hi << 4 | lo)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
