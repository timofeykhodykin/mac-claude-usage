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
        // The shell can't be talked into running anything from the app's path.
        let tricky = StatusLineInstaller.command(forExecutable: "/Users/me/$(rm x)/`id`/a\\\"b/MacClaudeUsage")
        #expect(tricky == #""/Users/me/\$(rm x)/\`id\`/a\\\"b/MacClaudeUsage" --statusline"#)
        #expect(StatusLineInstaller.isOurs(tricky))
        #expect(StatusLineInstaller.command(forExecutable: "/Apps/Claude Usage.app/Contents/MacOS/MacClaudeUsage")
                == #""/Apps/Claude Usage.app/Contents/MacOS/MacClaudeUsage" --statusline"#)
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

@Suite struct UsageHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    var sessionReset: Date { t0.addingTimeInterval(4 * 3600) }
    var weekReset: Date { t0.addingTimeInterval(3 * 86400) }

    func point(_ minutes: Double, s: Double?, sr: Date? = nil, w: Double?, wr: Date? = nil) -> UsagePoint {
        UsagePoint(date: t0.addingTimeInterval(minutes * 60), session: s, sessionResetsAt: sr,
                   weekly: w, weeklyResetsAt: wr)
    }

    @Test func recordsChangesAndHeartbeats() {
        let last = point(0, s: 10, sr: sessionReset, w: 40, wr: weekReset)
        #expect(UsageHistory.shouldRecord(last, after: nil))
        #expect(!UsageHistory.shouldRecord(point(1, s: 10, sr: sessionReset, w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(1, s: 11, sr: sessionReset, w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(1, s: 10, sr: sessionReset, w: 41, wr: weekReset), after: last))
        // Same reset reported with different precision: not a change.
        #expect(!UsageHistory.shouldRecord(point(1, s: 10, sr: sessionReset.addingTimeInterval(0.3), w: 40, wr: weekReset), after: last))
        // A new window is a change even at the same percentage.
        #expect(UsageHistory.shouldRecord(point(1, s: 10, sr: sessionReset.addingTimeInterval(5 * 3600), w: 40, wr: weekReset), after: last))
        #expect(UsageHistory.shouldRecord(point(10, s: 10, sr: sessionReset, w: 40, wr: weekReset), after: last))
        #expect(!UsageHistory.shouldRecord(point(-1, s: 50, sr: sessionReset, w: 40, wr: weekReset), after: last))
        #expect(!UsageHistory.shouldRecord(point(0, s: nil, w: nil), after: nil))
    }

    @Test func fileFormatRoundTrips() throws {
        let points = [point(0, s: 10, sr: sessionReset, w: 40, wr: weekReset), point(5, s: 12.5, w: nil)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for p in points.reversed() {
            data.append(try encoder.encode(p))
            data.append(Data("\nnot json\n".utf8))
        }
        #expect(UsageHistory.decode(data) == points)  // garbage skipped, sorted by date
        #expect(String(data: try encoder.encode(points[1]), encoding: .utf8)?.contains("\"s\":12.5") == true)
    }

    @Test func pruneKeepsRetention() {
        let old = point(-36 * 24 * 60, s: 1, w: 1)
        let recent = point(-34 * 24 * 60, s: 1, w: 1)
        let future = point(2 * 60, s: 1, w: 1)
        #expect(UsageHistory.pruned([old, recent, future], now: t0) == [recent])
    }

    @Test func sessionsPerWeekFromDeltas() throws {
        let r1 = t0.addingTimeInterval(5 * 3600), r2 = t0.addingTimeInterval(11 * 3600)
        let points = [
            // Session not started yet, then the first window: 0 → 60%, weekly 10 → 18%.
            point(0, s: 0, w: 10, wr: weekReset),
            point(30, s: 20, sr: r1, w: 13, wr: weekReset),
            point(120, s: 60, sr: r1, w: 18, wr: weekReset),
            // Next window, seen first at 5% (that pair crosses a reset and is skipped).
            point(400, s: 5, sr: r2, w: 19, wr: weekReset),
            point(500, s: 65, sr: r2, w: 27, wr: weekReset)
        ]
        let estimate = try #require(UsageHistory.sessionsEstimate(points, currentWeekly: 27, now: points[4].date))
        // Session grew 60 + 60, weekly 8 + 8: 7.5 full sessions per week, 73 / 13.33 left.
        #expect(estimate.sessions == 2)
        #expect(abs(try #require(estimate.perWeek.value) - 7.5) < 1e-9)
        #expect(abs(try #require(estimate.remaining.value) - 73 / (100 / 7.5)) < 1e-9)
        // Both sessions agree exactly, so only rounding to whole percent is left: a few percent.
        #expect(estimate.relativeError > 0.03 && estimate.relativeError < 0.1)
        #expect(SessionsLabel.text(estimate).hasPrefix("≈ 5.5 ± 0."))
        #expect(SessionsLabel.text(estimate).hasSuffix(" of 7.5 ± 0.6 full sessions left"))
    }

    @Test func estimateShowsUpWithLittleData() throws {
        let r = sessionReset
        // Weekly moved 2 points: a range.
        let some = [point(0, s: 0, sr: r, w: 10, wr: weekReset), point(30, s: 20, sr: r, w: 12, wr: weekReset)]
        let ranged = try #require(UsageHistory.sessionsEstimate(some, currentWeekly: 12, now: some[1].date))
        #expect(ranged.relativeError > 0.35 && ranged.relativeError <= 0.5)
        #expect(SessionsLabel.text(ranged).contains("–"))
        #expect(SessionsLabel.text(ranged).hasSuffix("full sessions left"))

        // Weekly moved a single point: too rough to show, the tooltip has the range.
        let one = [point(0, s: 11, sr: r, w: 2, wr: weekReset), point(14, s: 15, sr: r, w: 3, wr: weekReset)]
        let rough = try #require(UsageHistory.sessionsEstimate(one, currentWeekly: 3, now: one[1].date))
        #expect(SessionsLabel.text(rough) == "Sessions left: estimating, needs a bit more use…")
        #expect(SessionsLabel.help(rough).contains("So far: "))

        // Weekly hasn't moved yet: only a lower bound so far.
        let tiny = [point(0, s: 0, sr: r, w: 14, wr: weekReset), point(30, s: 3, sr: r, w: 14, wr: weekReset)]
        let bound = try #require(UsageHistory.sessionsEstimate(tiny, currentWeekly: 14, now: tiny[1].date))
        #expect(bound.perWeek.value == nil && bound.perWeek.high == nil)
        #expect(SessionsLabel.help(bound).contains("So far: at least 3.2 of at least 3.7 full sessions left"))

        // Nothing used at all: nothing to say.
        let idle = [point(0, s: 5, sr: r, w: 14, wr: weekReset), point(30, s: 5, sr: r, w: 14, wr: weekReset)]
        #expect(UsageHistory.sessionsEstimate(idle, currentWeekly: 14, now: idle[1].date) == nil)
        #expect(SessionsLabel.text(nil) == "Sessions left: learning from your usage…")
    }

    @Test func weeklyTicksSharpenTheEstimate() throws {
        // The status line reports after every reply, a session point at a time; the weekly
        // percentage steps up at 3, 10 and 17. Between the first and last step the week grew
        // exactly 2 points while the session grew 16.5 - 2.5 = 14.
        var points: [UsagePoint] = []
        for s in 0...19 {
            let w = 10 + (s >= 3 ? 1 : 0) + (s >= 10 ? 1 : 0) + (s >= 17 ? 1 : 0)
            points.append(point(Double(s), s: Double(s), sr: sessionReset, w: Double(w), wr: weekReset))
        }
        let chunk = try #require(UsageHistory.chunks(points, since: t0).first)
        #expect(chunk.session == 14 && chunk.weekly == 2 && chunk.weeklyVariance == 0)
        let estimate = try #require(UsageHistory.sessionsEstimate(points, currentWeekly: 13, now: points[19].date))
        #expect(abs(try #require(estimate.perWeek.value) - 7) < 1e-9)
        // End to end (3 weekly points ± rounding) would be ±27%; the ticks give under ±10%.
        #expect(estimate.relativeError < 0.1)
        #expect(SessionsLabel.text(estimate).hasPrefix("≈ 6.1 ± 0."))
    }

    @Test func coarseTicksFallBackToEndToEnd() throws {
        // Polled rarely: the steps are too wide to locate the ticks, so the totals win.
        let points = [point(0, s: 0, sr: sessionReset, w: 10, wr: weekReset),
                      point(30, s: 20, sr: sessionReset, w: 13, wr: weekReset),
                      point(120, s: 60, sr: sessionReset, w: 18, wr: weekReset)]
        let chunk = try #require(UsageHistory.chunks(points, since: t0).first)
        #expect(chunk.session == 60 && chunk.weekly == 8)
    }

    /// One session window `daysAgo` before t0, in which the session grew by `ds` and the week by `dw`.
    func session(daysAgo: Double, ds: Double, dw: Double) -> [UsagePoint] {
        let start = t0.addingTimeInterval(-daysAgo * 86400)
        let reset = start.addingTimeInterval(5 * 3600)
        return [UsagePoint(date: start, session: 0, sessionResetsAt: reset, weekly: 20, weeklyResetsAt: reset.addingTimeInterval(86400)),
                UsagePoint(date: start.addingTimeInterval(3 * 3600), session: ds, sessionResetsAt: reset,
                           weekly: 20 + dw, weeklyResetsAt: reset.addingTimeInterval(86400))]
    }

    @Test func recentSessionsWeighMore() throws {
        let chunks = [UsageChunk(start: t0, end: t0, session: 60, weekly: 12),
                      UsageChunk(start: t0, end: t0, session: 60, weekly: 6)]
        let even = try #require(UsageHistory.fitCost(chunks, weights: [1, 1]))
        let recent = try #require(UsageHistory.fitCost(chunks, weights: [0.25, 1]))
        #expect(abs(even.cost - 0.15) < 1e-9)
        #expect(abs(recent.cost - (0.25 * 12 + 6) / (0.25 * 60 + 60)) < 1e-9)
    }

    @Test func limitChangeDropsOlderData() throws {
        // Two weeks at 12% of the week per full session, then the limits halve it to 6%.
        var points: [UsagePoint] = []
        for day in stride(from: 20.0, through: 8, by: -2) { points += session(daysAgo: day, ds: 60, dw: 7.2.rounded()) }
        for day in [5.0, 3, 1] { points += session(daysAgo: day, ds: 60, dw: 4) }
        let estimate = try #require(UsageHistory.sessionsEstimate(points, currentWeekly: 20, now: t0))
        #expect(estimate.sessions == 3)
        #expect(estimate.limitsChangedAt == t0.addingTimeInterval(-5 * 86400))
        #expect(abs(estimate.cost - 4.0 / 60) < 1e-9)
        #expect(SessionsLabel.help(estimate).contains("seem to have changed"))
    }

    @Test func roundingNoiseIsNotALimitChange() throws {
        // Same limits; the weekly growth per session just rounds to 7 or 8.
        var points: [UsagePoint] = []
        for (i, day) in stride(from: 20.0, through: 1, by: -1.5).enumerated() {
            points += session(daysAgo: day, ds: 55 + Double(i % 3) * 5, dw: [7, 8, 8, 7, 9][i % 5])
        }
        let estimate = try #require(UsageHistory.sessionsEstimate(points, currentWeekly: 40, now: t0))
        #expect(estimate.limitsChangedAt == nil)
        #expect(estimate.sessions == 13)
        #expect(estimate.relativeError < 0.15)
    }

    @Test func weeklyResetBreaksThePair() {
        let a = point(0, s: 10, sr: sessionReset, w: 90, wr: t0.addingTimeInterval(60))
        let b = point(5, s: 20, sr: sessionReset, w: 2, wr: weekReset)
        #expect(UsageHistory.growth(.session, from: a, to: b) == 10)
        #expect(UsageHistory.growth(.weekly, from: a, to: b) == nil)
    }
}

@Suite struct UsageChartModelTests {
    let end = Date(timeIntervalSince1970: 1_790_018_000)
    var start: Date { end.addingTimeInterval(-5 * 3600) }

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    func points(_ values: [(Double, Double)]) -> [UsagePoint] {
        values.map { UsagePoint(date: at($0.0), session: $0.1, sessionResetsAt: end, weekly: 50,
                                weeklyResetsAt: end.addingTimeInterval(86400)) }
    }

    @Test func samplesStayInTheWindow() {
        var history = points([(10, 5), (20, 8)])
        // From the previous window and from a different reset: left out.
        history.insert(UsagePoint(date: at(-30), session: 90, sessionResetsAt: start, weekly: 40, weeklyResetsAt: nil), at: 0)
        history.append(UsagePoint(date: at(25), session: 3, sessionResetsAt: end.addingTimeInterval(3600), weekly: 50, weeklyResetsAt: nil))
        let model = UsageChartModel.make(points: history, metric: .session, resetsAt: end, now: at(30))!
        #expect(model.samples.map(\.value) == [0, 5, 8, 8])
        #expect(model.samples.first?.date == start)
        #expect(model.samples.last?.date == at(30))
        #expect(UsageChartModel.make(points: history, metric: .session, resetsAt: at(-1), now: at(30)) == nil)
        #expect(UsageChartModel.make(points: history, metric: .session, resetsAt: nil, now: at(30)) == nil)
    }

    @Test func unwatchedStretchesSplitTheLine() {
        let samples = [(0.0, 0.0), (5, 4), (10, 6), (120, 30), (125, 32)].map {
            UsageSample(date: at($0.0), value: $0.1)
        }
        let lines = UsageChartModel.lines(samples)
        #expect(lines.map(\.watched) == [true, false, true])
        #expect(lines.map(\.samples.count) == [3, 2, 2])
    }

    @Test func trendsPerStretchOfUse() throws {
        // 12%/h for 30 min, an idle half hour (heartbeats), then 30%/h for 20 min.
        let model = UsageChartModel.make(points: points([(0, 0), (10, 2), (20, 4), (30, 6), (40, 6), (50, 6), (60, 6),
                                                         (70, 11), (80, 16)]),
                                         metric: .session, resetsAt: end, now: at(82))!
        #expect(model.trends.count == 2)
        let first = try #require(model.trends.first), second = try #require(model.trends.last)
        #expect(abs(first.perHour - 12) < 1e-6)
        #expect(first.start.date == at(0) && first.end.date == at(30))
        #expect(abs(second.perHour - 30) < 1e-6)
        #expect(second.start.date == at(60))

        // Still going: 16% + 30%/h hits 100% after 2h 48m, before the reset 3h 38m away.
        let projection = try #require(model.projection)
        #expect(projection.hitsLimit)
        #expect(abs(projection.to.date.timeIntervalSince(at(82 + 168))) < 1)
        #expect(UsageChart.caption(model, time: { _ in "T" }) == "At 30%/h you'd hit the limit at T")
    }

    @Test func projectionStopsAtResetAndWhenIdle() throws {
        let slow = UsageChartModel.make(points: points([(200, 0), (210, 1), (220, 2), (230, 3)]),
                                        metric: .session, resetsAt: end, now: at(230))!
        let projection = try #require(slow.projection)
        #expect(!projection.hitsLimit)
        #expect(projection.to.date == end)
        #expect(abs(projection.to.value - (3 + 6 * 70.0 / 60)) < 1e-6)
        #expect(UsageChart.caption(slow) == "At 6.0%/h: ≈ 10% by the reset")

        let idle = UsageChartModel.make(points: points([(200, 0), (210, 1), (220, 2), (230, 3)]),
                                        metric: .session, resetsAt: end, now: at(260))!
        #expect(idle.projection == nil)
        #expect(UsageChart.caption(idle) == "Last active stretch: 6.0%/h")
    }

    @Test func noTrendFromASingleStep() {
        // First seen long after the window started: the rise before that wasn't watched.
        let model = UsageChartModel.make(points: points([(100, 1), (102, 2)]), metric: .session, resetsAt: end, now: at(103))!
        #expect(model.trends.isEmpty)
        #expect(UsageChart.caption(model) == nil)
    }

    @Test func hourMarksAvoidEdges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_790_000_000 - 1_790_000_000.truncatingRemainder(dividingBy: 3600) + 50 * 60)
        let marks = UsageChart.hourMarks(in: DateInterval(start: start, duration: 5 * 3600), calendar: calendar)
        // Window 12:50–17:50: 13:00 is 10 min from the start, so 14:00…17:00, but 17:00 is fine (50 min from the end).
        #expect(marks.count == 4)
        #expect(marks.first == start.addingTimeInterval(70 * 60))
    }

    @Test func hoverValueInterpolates() {
        let model = UsageChartModel.make(points: points([(10, 10), (20, 20)]), metric: .session, resetsAt: end, now: at(30))!
        #expect(model.value(at: at(15)) == 15)
        #expect(model.value(at: at(25)) == 20)
        #expect(model.value(at: at(31)) == nil)
    }

    @Test func weeklyCaptionComparesWithElapsedTime() {
        let weekEnd = start.addingTimeInterval(7 * 86400)
        let history = [UsagePoint(date: start.addingTimeInterval(3600), session: 5, sessionResetsAt: nil,
                                  weekly: 30, weeklyResetsAt: weekEnd)]
        let model = UsageChartModel.make(points: history, metric: .weekly, resetsAt: weekEnd,
                                         now: start.addingTimeInterval(3.5 * 86400))!
        #expect(UsageChart.caption(model) == "30% used · 50% of the week has passed")
        #expect(model.projection == nil)
    }
}
