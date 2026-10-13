import Foundation

/// The two limits, as a value for settings and for code that treats them alike.
enum UsageMetric: String, CaseIterable, Identifiable {
    case session
    case weekly

    var id: String { rawValue }

    /// How long one window lasts once it has started.
    var windowLength: TimeInterval {
        switch self {
        case .session: return 5 * 3600
        case .weekly: return 7 * 86400
        }
    }
}

/// One observation of both limits. Recorded whenever either changes, plus a heartbeat while
/// nothing changes, so a flat stretch can be told apart from a stretch nobody was watching
/// (Mac asleep, app not running).
struct UsagePoint: Codable, Equatable {
    var date: Date
    var session: Double?
    var sessionResetsAt: Date?
    var weekly: Double?
    var weeklyResetsAt: Date?

    /// Short keys: the history holds thousands of these.
    enum CodingKeys: String, CodingKey {
        case date = "t"
        case session = "s"
        case sessionResetsAt = "sr"
        case weekly = "w"
        case weeklyResetsAt = "wr"
    }

    init(date: Date, session: Double?, sessionResetsAt: Date?, weekly: Double?, weeklyResetsAt: Date?) {
        self.date = date
        self.session = session
        self.sessionResetsAt = sessionResetsAt
        self.weekly = weekly
        self.weeklyResetsAt = weeklyResetsAt
    }

    init(_ snapshot: UsageSnapshot) {
        self.init(date: snapshot.fetchedAt,
                  session: snapshot.session?.utilization, sessionResetsAt: snapshot.session?.resetsAt,
                  weekly: snapshot.weekly?.utilization, weeklyResetsAt: snapshot.weekly?.resetsAt)
    }

    func utilization(_ metric: UsageMetric) -> Double? {
        metric == .session ? session : weekly
    }

    func resetsAt(_ metric: UsageMetric) -> Date? {
        metric == .session ? sessionResetsAt : weeklyResetsAt
    }
}

/// How many full 5-hour sessions the weekly limit holds, learned from history.
struct SessionsEstimate: Equatable {
    /// Weekly percentage points that one percentage point of the session limit costs.
    var cost: Double
    /// Half-width of the ~95% range of `cost` (2σ).
    var costError: Double
    /// Weekly percentage points left.
    var weeklyLeft: Double
    /// How many session windows the estimate rests on, and since when.
    var sessions: Int
    var since: Date
    /// Set when older history was set aside because the limits seem to have changed then.
    var limitsChangedAt: Date?

    /// An estimate with its ~95% range. `value` and `high` are nil while the data can't rule
    /// out "practically unlimited" (the weekly percentage has barely moved yet).
    struct Bounds: Equatable {
        var value: Double?
        var low: Double
        var high: Double?
    }

    /// Full sessions (0 → 100% of the 5-hour limit) that fit in a whole weekly limit.
    var perWeek: Bounds { bounds(weeklyPoints: 100) }
    /// Full sessions that fit in what's left of the current weekly limit.
    var remaining: Bounds { bounds(weeklyPoints: weeklyLeft) }

    /// Relative uncertainty of `cost`, which carries over unchanged to both counts.
    var relativeError: Double { cost > 0 ? costError / cost : .infinity }

    private func bounds(weeklyPoints: Double) -> Bounds {
        let sessions = weeklyPoints / 100
        return Bounds(value: cost > 0 ? sessions / cost : nil,
                      low: sessions / (cost + costError),
                      high: cost > costError ? sessions / (cost - costError) : nil)
    }
}

/// Usage in one unbroken run of observations inside the same session and weekly window.
struct UsageChunk: Equatable {
    var start: Date
    var end: Date
    /// Growth of the session and weekly percentages over the run.
    var session: Double
    var weekly: Double
    /// Variance of the measurement error in `session` and `weekly`. By default both are
    /// differences of two values rounded to whole percent: 1/12 + 1/12.
    var sessionVariance: Double = 1.0 / 6
    var weeklyVariance: Double = 1.0 / 6

    /// Relative variance of `weekly / session`: lower is a sharper measurement.
    var relativeVariance: Double {
        guard session > 0, weekly > 0 else { return .infinity }
        return weeklyVariance / (weekly * weekly) + sessionVariance / (session * session)
    }
}

/// Usage history: an append-only JSON-lines file next to the status-line feed.
enum UsageHistory {
    static var fileURL: URL { LiveFeed.directory.appendingPathComponent("usage-history.jsonl") }

    /// Long enough for four full weekly windows plus the current one.
    static let retention: TimeInterval = 35 * 86400
    /// While usage doesn't change, record it again this often, to show we were watching.
    static let heartbeat: TimeInterval = 10 * 60
    /// Sources report the same reset time with different precision (microseconds vs whole
    /// seconds), so reset times this close mean the same window.
    static let resetTolerance: TimeInterval = 10 * 60
    /// How far back the sessions estimate looks at most; see `estimateHalfLife`.
    static let estimateLookback: TimeInterval = 28 * 86400

    // MARK: - Recording

    /// Whether `point` adds anything after `last`: a changed percentage, a new window, or a
    /// heartbeat after `heartbeat` without change.
    static func shouldRecord(_ point: UsagePoint, after last: UsagePoint?) -> Bool {
        guard let last else { return point.session != nil || point.weekly != nil }
        guard point.date > last.date else { return false }
        for metric in UsageMetric.allCases {
            let a = last.utilization(metric), b = point.utilization(metric)
            if (a == nil) != (b == nil) { return true }
            if let a, let b, abs(a - b) >= 0.05 { return true }
            if !sameReset(last.resetsAt(metric), point.resetsAt(metric)) { return true }
        }
        return point.date.timeIntervalSince(last.date) >= heartbeat
    }

    /// Both "not started", or both the same reset time within `resetTolerance`.
    static func sameReset(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < resetTolerance
        default: return false
        }
    }

    /// Drops entries past `retention`, and ones from the future (a clock that was off, a
    /// hand-edited file): new points must come after the last one, so those would block
    /// recording until their date.
    static func pruned(_ points: [UsagePoint], now: Date = Date()) -> [UsagePoint] {
        let cutoff = now.addingTimeInterval(-retention), latest = now.addingTimeInterval(60)
        return points.filter { $0.date >= cutoff && $0.date <= latest }
    }

    // MARK: - File

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func decode(_ data: Data) -> [UsagePoint] {
        let decoder = decoder
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(UsagePoint.self, from: Data($0)) }
            .sorted { $0.date < $1.date }
    }

    /// Reads the history, dropping entries past `retention` (and rewriting the file if any were).
    static func load(now: Date = Date()) -> [UsagePoint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let all = decode(data)
        let kept = pruned(all, now: now)
        if kept.count != all.count { rewrite(kept) }
        return kept
    }

    static func append(_ point: UsagePoint) {
        guard var line = try? encoder.encode(point) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: LiveFeed.directory, withIntermediateDirectories: true)
            try? line.write(to: fileURL, options: .atomic)
        }
    }

    static func rewrite(_ points: [UsagePoint]) {
        let encoder = encoder
        var data = Data()
        for point in points {
            guard let line = try? encoder.encode(point) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: LiveFeed.directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Sessions per week

    /// Compares how much the weekly and the 5-hour percentages grew inside the same windows.
    /// Gaps don't matter (usage while we weren't watching still shows up in both), and
    /// resets never look like usage.
    ///
    /// Limits can change, so recent data counts more (`estimateHalfLife`), and when the
    /// cost of a session percent clearly differs before and after some point, everything
    /// before it is set aside. Shown as soon as the session percentage has moved at all; the
    /// range says how much that's worth.
    static func sessionsEstimate(_ points: [UsagePoint], currentWeekly: Double?,
                                 now: Date = Date()) -> SessionsEstimate? {
        var chunks = chunks(points, since: now.addingTimeInterval(-estimateLookback))
        var changedAt: Date?
        if let split = limitChange(chunks) {
            changedAt = chunks[split].start
            chunks = Array(chunks[split...])
        }
        let weights = chunks.map { pow(0.5, max(0, now.timeIntervalSince($0.end)) / estimateHalfLife) }
        guard let first = chunks.first, let fit = fitCost(chunks, weights: weights) else { return nil }
        return SessionsEstimate(cost: fit.cost, costError: 2 * fit.sigma,
                                weeklyLeft: max(0, 100 - (currentWeekly ?? 0)),
                                sessions: chunks.count, since: first.start, limitsChangedAt: changedAt)
    }

    /// Recent data counts more: a session from a week ago weighs half as much as today's.
    static let estimateHalfLife: TimeInterval = 7 * 86400
    /// How many standard errors apart two halves of the history must be to call it a change.
    static let limitChangeThreshold = 3.0

    /// Splits the history into runs of consecutive observations within the same windows
    /// (in practice, one per session). Percentages are rounded, but deltas telescope, so
    /// each run carries the rounding error of its two ends only.
    static func chunks(_ points: [UsagePoint], since cutoff: Date) -> [UsageChunk] {
        var result: [UsageChunk] = []
        var run: [(start: Date, end: Date, session: Double, weekly: Double)] = []
        func flush() {
            if let chunk = chunk(run) { result.append(chunk) }
            run = []
        }
        for (previous, next) in zip(points, points.dropFirst()) {
            guard previous.date >= cutoff,
                  let ds = growth(.session, from: previous, to: next),
                  let dw = growth(.weekly, from: previous, to: next) else {
                flush()
                continue
            }
            run.append((previous.date, next.date, ds, dw))
        }
        flush()
        return result
    }

    /// One run as a measurement, the sharper of two:
    ///
    /// - **End to end**: total growth of both; the weekly side is off by up to a point from
    ///   rounding, which dominates while the weekly percentage has moved only a few points.
    /// - **Between weekly ticks**: when the weekly percentage steps up, it has just crossed a
    ///   rounding boundary. From the first such step to the last, the week grew by an exact
    ///   number of points, and only the session side is uncertain (by how far the session
    ///   moved between the two observations around each step). With the status line
    ///   reporting after every reply, that's a point or two.
    static func chunk(_ run: [(start: Date, end: Date, session: Double, weekly: Double)]) -> UsageChunk? {
        guard let first = run.first, let last = run.last else { return nil }
        var endToEnd = UsageChunk(start: first.start, end: last.end,
                                  session: run.reduce(0) { $0 + $1.session },
                                  weekly: run.reduce(0) { $0 + $1.weekly })
        guard endToEnd.session > 0 || endToEnd.weekly > 0 else { return nil }

        var session = 0.0, weekly = 0.0
        var ticks: [(session: Double, weekly: Double, variance: Double)] = []
        for step in run {
            if step.weekly > 0 {
                // Somewhere in this step; the midpoint is off by a uniform error over its width,
                // plus the rounding of the session values themselves.
                ticks.append((session + step.session / 2, weekly + step.weekly,
                              step.session * step.session / 12 + 1.0 / 12))
            }
            session += step.session
            weekly += step.weekly
        }
        if let a = ticks.first, let b = ticks.last, b.weekly > a.weekly, b.session > a.session {
            let betweenTicks = UsageChunk(start: first.start, end: last.end,
                                          session: b.session - a.session, weekly: b.weekly - a.weekly,
                                          sessionVariance: a.variance + b.variance, weeklyVariance: 0)
            if betweenTicks.relativeVariance < endToEnd.relativeVariance { endToEnd = betweenTicks }
        }
        return endToEnd
    }

    /// Weighted ratio estimate of weekly points per session point, with its standard error:
    /// the spread between runs, but never less than the runs' own measurement error explains.
    static func fitCost(_ chunks: [UsageChunk], weights: [Double]) -> (cost: Double, sigma: Double)? {
        let sessionTotal = zip(chunks, weights).reduce(0) { $0 + $1.1 * $1.0.session }
        guard sessionTotal > 0 else { return nil }
        let cost = zip(chunks, weights).reduce(0) { $0 + $1.1 * $1.0.weekly } / sessionTotal
        let sumW = weights.reduce(0, +)
        let sumW2 = weights.reduce(0) { $0 + $1 * $1 }
        let residuals = zip(chunks, weights).reduce(0) { total, item in
            let (chunk, w) = item
            let r = chunk.weekly - cost * chunk.session
            return total + w * w * r * r
        }
        let effectiveCount = sumW * sumW / sumW2
        let spread = effectiveCount > 1.5 ? residuals * effectiveCount / (effectiveCount - 1) : 0
        let measurement = zip(chunks, weights).reduce(0) { total, item in
            let (chunk, w) = item
            return total + w * w * (chunk.weeklyVariance + cost * cost * chunk.sessionVariance)
        }
        return (cost, max(spread, measurement).squareRoot() / sessionTotal)
    }

    /// The run where the limits seem to have changed: the split with the most significant
    /// difference in cost between before and after, if it's beyond `limitChangeThreshold`.
    /// Each side needs half a session of data to be compared at all.
    static func limitChange(_ chunks: [UsageChunk]) -> Int? {
        var best: (index: Int, z: Double)?
        for split in chunks.indices.dropFirst() {
            let before = Array(chunks[..<split]), after = Array(chunks[split...])
            guard before.reduce(0, { $0 + $1.session }) >= 50, after.reduce(0, { $0 + $1.session }) >= 50,
                  let a = fitCost(before, weights: before.map { _ in 1 }),
                  let b = fitCost(after, weights: after.map { _ in 1 }) else { continue }
            let z = abs(a.cost - b.cost) / (a.sigma * a.sigma + b.sigma * b.sigma).squareRoot()
            if z > (best?.z ?? 0) { best = (split, z) }
        }
        guard let best, best.z > limitChangeThreshold else { return nil }
        return best.index
    }

    /// Growth of `metric` from one observation to the next, or nil if they're in different
    /// windows (a window that hadn't started yet counts as the start of the next one).
    static func growth(_ metric: UsageMetric, from a: UsagePoint, to b: UsagePoint) -> Double? {
        guard let before = a.utilization(metric), let after = b.utilization(metric) else { return nil }
        if let resetA = a.resetsAt(metric) {
            guard let resetB = b.resetsAt(metric), abs(resetA.timeIntervalSince(resetB)) < resetTolerance,
                  resetA > a.date else { return nil }
        }
        let delta = after - before
        return delta >= 0 ? delta : nil
    }
}
