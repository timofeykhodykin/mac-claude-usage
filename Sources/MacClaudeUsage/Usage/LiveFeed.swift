import Foundation

/// Usage numbers that Claude Code hands us for free, without calling the rate-limited
/// usage endpoint.
///
/// - **Status line feed.** Claude Code runs our binary as its status-line command after every
///   response and passes `rate_limits` (5h / 7d used % and reset time) on stdin. The
///   `--statusline` process writes them to `feedURL`; the menu bar app picks them up.
/// - **`~/.claude.json` → `cachedUsageUtilization`.** Claude Code's cache from its own
///   `/usage` command.
enum LiveFeed {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacClaudeUsage", isDirectory: true)
    }

    static var feedURL: URL { directory.appendingPathComponent("statusline-feed.json") }

    static func write(_ snapshot: UsageSnapshot) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: feedURL, options: .atomic)
    }

    static func readStatusLineFeed() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: feedURL) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// Claude Code only refreshes this cache when you run `/usage`, so older entries are noise.
    static let claudeCacheMaxAge: TimeInterval = 60 * 60

    /// Claude Code's own cached `/usage` result, if recent.
    static func readClaudeCache() -> UsageSnapshot? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url), let snapshot = parseClaudeCache(data),
              Date().timeIntervalSince(snapshot.fetchedAt) < claudeCacheMaxAge else { return nil }
        return snapshot
    }

    static func parseClaudeCache(_ data: Data) -> UsageSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = utilization[key] as? [String: Any],
                  let value = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(utilization: value, resetsAt: UsageAPI.parseDate(w["resets_at"] as? String))
        }
        let snapshot = UsageSnapshot(session: window("five_hour"), weekly: window("seven_day"),
                                     fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
                                     source: .claudeCache)
        return snapshot.session == nil && snapshot.weekly == nil ? nil : snapshot
    }
}

/// Entry point for `MacClaudeUsage --statusline`, run by Claude Code as its status-line command.
enum StatusLineCommand {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            Log.usage.error("Status line: unreadable payload (\(input.count, privacy: .public) bytes)")
            return
        }
        if let snapshot = parseRateLimits(payload) {
            LiveFeed.write(snapshot)
            Log.usage.info("Status line: saved rate limits, session \(snapshot.session?.utilization ?? -1, privacy: .public)%")
        } else {
            Log.usage.info("Status line: no rate_limits in payload (keys: \(payload.keys.sorted().joined(separator: ","), privacy: .public))")
        }
        let line = render(payload)
        if !line.isEmpty { print(line) }
    }

    static func parseRateLimits(_ payload: [String: Any], now: Date = Date()) -> UsageSnapshot? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> UsageWindow? {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(utilization: used, resetsAt: resets)
        }
        let snapshot = UsageSnapshot(session: window("five_hour"), weekly: window("seven_day"),
                                     fetchedAt: now, source: .statusLine)
        return snapshot.session == nil && snapshot.weekly == nil ? nil : snapshot
    }

    /// Same readout as before: `Opus 4.8 · 11% · 113K/1M` (context window of this session).
    static func render(_ payload: [String: Any]) -> String {
        var parts: [String] = []
        let model = payload["model"] as? [String: Any]
        if let name = (model?["display_name"] as? String) ?? (model?["id"] as? String) {
            parts.append(name)
        }
        let context = payload["context_window"] as? [String: Any]
        if let pct = (context?["used_percentage"] as? NSNumber)?.doubleValue {
            parts.append("\(Int(pct))%")
        }
        if let usage = context?["current_usage"] as? [String: Any],
           let size = (context?["context_window_size"] as? NSNumber)?.intValue {
            let total = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .compactMap { (usage[$0] as? NSNumber)?.intValue }
                .reduce(0, +)
            parts.append("\(compact(total))/\(compact(size))")
        }
        return parts.joined(separator: " · ")
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))K" }
        return "\(n)"
    }
}
