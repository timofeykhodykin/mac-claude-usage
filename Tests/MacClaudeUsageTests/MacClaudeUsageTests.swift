import Foundation
import Testing
@testable import MacClaudeUsage

@Suite struct KeychainDecodingTests {
    @Test func plainJSONPassesThrough() throws {
        let data = try ClaudeKeychain.decodePassword(Data("{\"a\":1}\n".utf8))
        #expect(String(data: data, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func hexOutputIsDecoded() throws {
        let hex = Data("{\"a\":1}".utf8).map { String(format: "%02x", $0) }.joined()
        let data = try ClaudeKeychain.decodePassword(Data((hex + "\n").utf8))
        #expect(String(data: data, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func garbageIsRejected() {
        #expect(throws: KeychainError.self) { try ClaudeKeychain.decodePassword(Data("nope".utf8)) }
    }
}

@Suite struct CredentialsTests {
    let sample = """
    {"claudeAiOauth":{"accessToken":"old-a","refreshToken":"old-r","expiresAt":1781211869970,
     "scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"tier",
     "futureField":"keep"},
     "mcpOAuth":{"server":{"accessToken":"mcp-token"}}}
    """

    @Test func applyPreservesUnrelatedFields() throws {
        var creds = try ClaudeCredentials(json: Data(sample.utf8))
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        creds.apply(RefreshedTokens(accessToken: "new-a", refreshToken: "new-r", expiresAt: expiry,
                                    refreshTokenExpiresAt: nil, scopes: ["user:inference"]))
        let roundTrip = try ClaudeCredentials(json: creds.jsonData())
        #expect(roundTrip.accessToken == "new-a")
        #expect(roundTrip.refreshToken == "new-r")
        #expect(roundTrip.expiresAt == expiry)
        #expect(roundTrip.subscriptionType == "max")

        let root = try JSONSerialization.jsonObject(with: creds.jsonData()) as! [String: Any]
        let oauth = root["claudeAiOauth"] as! [String: Any]
        #expect(oauth["futureField"] as? String == "keep")
        #expect(oauth["rateLimitTier"] as? String == "tier")
        #expect(((root["mcpOAuth"] as! [String: Any])["server"] as! [String: Any])["accessToken"] as? String == "mcp-token")
        #expect(oauth["expiresAt"] as? Int64 == 1_900_000_000_000)
    }

    @Test func refreshThresholdMatchesClaudeCode() throws {
        let creds = try ClaudeCredentials(json: Data(sample.utf8))
        let expiry = creds.expiresAt!
        #expect(!creds.needsRefresh(now: expiry.addingTimeInterval(-301)))
        #expect(creds.needsRefresh(now: expiry.addingTimeInterval(-299)))
    }
}

@Suite struct DirectoryLockTests {
    func tempPath() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("lock-\(UUID().uuidString)")
    }

    @Test func exclusiveUntilReleased() {
        let path = tempPath()
        let first = DirectoryLock.tryAcquire(path, stale: 60)
        #expect(first != nil)
        #expect(DirectoryLock.tryAcquire(path, stale: 60) == nil)
        first?.release()
        let again = DirectoryLock.tryAcquire(path, stale: 60)
        #expect(again != nil)
        again?.release()
    }

    @Test func staleLockIsTakenOver() throws {
        let path = tempPath()
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let old = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
        let lock = DirectoryLock.tryAcquire(path, stale: 60)
        #expect(lock != nil)
        lock?.release()
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

@Suite struct UsageParsingTests {
    @Test func parsesLegacyShape() throws {
        let json = """
        {"five_hour":{"utilization":39.0,"resets_at":"2026-06-11T18:00:00.308440+00:00"},
         "seven_day":{"utilization":44.0,"resets_at":"2026-06-16T18:00:00+00:00"},
         "seven_day_sonnet":null}
        """
        let snapshot = try UsageAPI.parse(Data(json.utf8))
        #expect(snapshot.session?.utilization == 39)
        #expect(snapshot.weekly?.utilization == 44)
        #expect(snapshot.session?.resetsAt != nil)
        #expect(snapshot.weekly?.resetsAt != nil)
    }

    @Test func fallsBackToLimitsArray() throws {
        let json = """
        {"five_hour":null,"limits":[
          {"kind":"session","percent":12,"resets_at":"2026-06-11T18:00:00Z"},
          {"kind":"weekly_all","percent":57,"resets_at":null}]}
        """
        let snapshot = try UsageAPI.parse(Data(json.utf8))
        #expect(snapshot.session?.utilization == 12)
        #expect(snapshot.weekly?.utilization == 57)
        #expect(snapshot.weekly?.resetsAt == nil)
    }

    @Test func retryAfterFormats() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(UsageAPI.parseRetryAfter("120", now: now) == 120)
        #expect(UsageAPI.parseRetryAfter(nil, now: now) == nil)
        let date = UsageAPI.parseRetryAfter("Mon, 12 Jan 1970 13:47:40 GMT", now: now)
        #expect(date == 60)
    }

    @Test func microsecondTimestamps() {
        let date = UsageAPI.parseDate("2026-06-11T18:00:00.508711+00:00")
        let expected = ISO8601DateFormatter().date(from: "2026-06-11T18:00:00Z")!.addingTimeInterval(0.508)
        #expect(date.map { abs($0.timeIntervalSince(expected)) < 0.002 } == true)
    }
}

@Suite struct LiveFeedTests {
    @Test func statusLinePayload() throws {
        let json = """
        {"model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},
         "context_window":{"context_window_size":1000000,"used_percentage":11.4,
           "current_usage":{"input_tokens":1000,"output_tokens":2000,"cache_creation_input_tokens":10000,"cache_read_input_tokens":100000}},
         "rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1790350000},
                        "seven_day":{"used_percentage":34.5,"resets_at":1790700000}}}
        """
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        #expect(StatusLineCommand.render(payload) == "Opus 5.5 · 11% · 113K/1M")
        let snapshot = try #require(StatusLineCommand.parseRateLimits(payload))
        #expect(snapshot.session?.utilization == 42)
        #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_790_350_000))
        #expect(snapshot.weekly?.utilization == 34.5)
        #expect(snapshot.source == .statusLine)
    }

    @Test func statusLineWithoutRateLimits() {
        #expect(StatusLineCommand.parseRateLimits(["model": ["id": "x"]]) == nil)
    }

    @Test func claudeJSONCache() throws {
        let json = """
        {"numStartups":3,"cachedUsageUtilization":{"fetchedAtMs":1790003175793,"accountUuid":"x",
          "utilization":{"five_hour":{"utilization":0,"resets_at":null},
                         "seven_day":{"utilization":34,"resets_at":"2026-09-30T10:00:00.123456+00:00"}}}}
        """
        let snapshot = try #require(LiveFeed.parseClaudeCache(Data(json.utf8)))
        #expect(snapshot.session?.utilization == 0)
        #expect(snapshot.weekly?.utilization == 34)
        #expect(snapshot.weekly?.resetsAt != nil)
        #expect(snapshot.source == .claudeCache)
        #expect(abs(snapshot.fetchedAt.timeIntervalSince1970 - 1_790_003_175.793) < 0.001)
    }

    @Test func windowResetsToZero() {
        let now = Date()
        let past = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(-1))
        let future = UsageWindow(utilization: 80, resetsAt: now.addingTimeInterval(60))
        #expect(past.currentUtilization(now: now) == 0)
        #expect(future.currentUtilization(now: now) == 80)
    }

    @Test func oldCachedSnapshotsStillDecode() throws {
        let old = #"{"fetchedAt":770000000,"session":{"utilization":5}}"#
        let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: Data(old.utf8))
        #expect(snapshot.session?.utilization == 5)
    }
}

@Suite struct FormattingTests {
    @Test func barColorFollowsScale() {
        func close(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Bool {
            abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9
        }
        let stops = UsageBar.pastelStops
        #expect(close(UsageBar.rgb(at: 0), stops[0]))
        #expect(close(UsageBar.rgb(at: 1), stops[3]))
        #expect(close(UsageBar.rgb(at: 1.0 / 3), stops[1]))
        #expect(close(UsageBar.rgb(at: 1.5), stops[3]))   // clamped
        #expect(close(UsageBar.rgb(at: -1), stops[0]))
        let mid = UsageBar.rgb(at: 1.0 / 6)                // halfway green → yellow
        #expect(close(mid, ((stops[0].r + stops[1].r) / 2, (stops[0].g + stops[1].g) / 2, (stops[0].b + stops[1].b) / 2)))
    }

    @Test func absoluteResetLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let locale = Locale(identifier: "en_GB")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 20))!
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        #expect(UsageRow.absoluteReset(at(27, 23), now: now, calendar: calendar, locale: locale) == "today 23:00")
        #expect(UsageRow.absoluteReset(at(28, 1), now: now, calendar: calendar, locale: locale) == "tomorrow 01:00")
        #expect(UsageRow.absoluteReset(at(30, 12), now: now, calendar: calendar, locale: locale) == "30 Sep 12:00")
    }

    @Test func ageCounter() {
        #expect(UpdatedLabel.age(0) == "0s")
        #expect(UpdatedLabel.age(42.9) == "42s")
        #expect(UpdatedLabel.age(65) == "1m 05s")
        #expect(UpdatedLabel.age(750) == "12m 30s")
        #expect(UpdatedLabel.age(3900) == "1h 05m")
        #expect(UpdatedLabel.age(2 * 86400 + 3 * 3600) == "2d 3h")
        #expect(UpdatedLabel.age(-5) == "0s")
    }

    @Test func statusLineOwnership() {
        let app = "\"/Users/me/Applications/Claude Usage.app/Contents/MacOS/"
        #expect(StatusLineInstaller.isOurs(app + "MacClaudeUsage\" --statusline"))
        #expect(!StatusLineInstaller.isOurs(app + "MacClaudeUsage\""))
        #expect(!StatusLineInstaller.isOurs("ccusage statusline"))
        // The old MiniBar app's status line gets repointed to us; nobody else's does.
        #expect(StatusLineInstaller.isReplaceable("\"/Apps/ClaudeUsageMiniBar\" --statusline"))
        #expect(!StatusLineInstaller.isReplaceable("ccusage statusline"))
    }

    @Test func menuBarText() {
        let now = Date()
        let snapshot = UsageSnapshot(session: UsageWindow(utilization: 12.6, resetsAt: now.addingTimeInterval(3600)),
                                     weekly: UsageWindow(utilization: 5, resetsAt: now.addingTimeInterval(-60)),
                                     fetchedAt: now)
        func text(_ s: UsageSnapshot?, weekly: Bool, unavailable: Bool = false) -> String {
            MenuBarLabel.text(snapshot: s, showWeekly: weekly, unavailable: unavailable, now: now)
        }
        #expect(text(snapshot, weekly: false) == "13%")
        #expect(text(snapshot, weekly: true) == "13% / 0%") // weekly window already reset
        #expect(text(snapshot, weekly: false, unavailable: true) == "?")
        #expect(text(snapshot, weekly: true, unavailable: true) == "? / ?")
        #expect(text(UsageSnapshot(session: nil, weekly: nil, fetchedAt: now), weekly: true) == "–% / –%")
    }
}

/// Exercises the real `security -i` write path against a throwaway item (never Claude Code's).
@Suite struct KeychainRoundTripTests {
    @Test func writeThenReadThroughSecurityTool() throws {
        let keychain = ClaudeKeychain(service: "MacClaudeUsage-selftest-\(UUID().uuidString)",
                                      account: ClaudeKeychain.claudeCodeAccount())
        defer {
            _ = try? ProcessRunner.run(ClaudeKeychain.securityTool,
                                       ["delete-generic-password", "-a", keychain.account, "-s", keychain.service])
        }
        let first = Data(#"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","url":"https://x/y"}}"#.utf8)
        try keychain.write(first)
        #expect(try keychain.read() == first)

        // Update in place (-U), like a refresh does.
        let second = Data(#"{"claudeAiOauth":{"accessToken":"a2","refreshToken":"r2"}}"#.utf8)
        try keychain.write(second)
        #expect(try keychain.read() == second)
    }
}
