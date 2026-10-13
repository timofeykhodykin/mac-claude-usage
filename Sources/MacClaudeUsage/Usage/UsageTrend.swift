import Foundation

struct UsageSample: Equatable {
    var date: Date
    var value: Double
}

/// A run of the chart's line: either watched (consecutive observations close together) or a
/// stretch nobody was watching, where we only know the values at both ends.
struct UsageLine: Equatable, Identifiable {
    let id: Int
    let watched: Bool
    var samples: [UsageSample]
}

/// A least-squares line through one stretch of active use.
struct TrendLine: Equatable {
    var start: UsageSample
    var end: UsageSample
    /// Percentage points per hour.
    var perHour: Double
}

/// Where the current stretch of use leads if it keeps its pace.
struct Projection: Equatable {
    var from: UsageSample
    var to: UsageSample
    var perHour: Double
    /// True when the limit is hit before the window resets (`to` is then at 100%).
    var hitsLimit: Bool
}

/// Everything the chart draws for one window of one limit, computed from the history.
struct UsageChartModel: Equatable {
    let metric: UsageMetric
    let window: DateInterval
    /// Observations in this window, oldest first: starts with 0% at the window start and,
    /// while the window is open, ends with the latest value carried to `now`.
    let samples: [UsageSample]
    let lines: [UsageLine]
    let trends: [TrendLine]
    let projection: Projection?
    let now: Date

    /// Observations further apart than this leave a stretch we didn't see.
    static let gapThreshold: TimeInterval = 45 * 60
    /// A stretch of use ends after this long without the percentage going up.
    static let idleBreak: TimeInterval = 20 * 60

    var current: UsageSample? { samples.last }

    /// The window ending at `resetsAt`, or nil when there's no open window to chart.
    static func make(points: [UsagePoint], metric: UsageMetric, resetsAt: Date?,
                     now: Date = Date()) -> UsageChartModel? {
        guard let end = resetsAt, end > now else { return nil }
        let start = end.addingTimeInterval(-metric.windowLength)
        let samples = samples(points: points, metric: metric, window: DateInterval(start: start, end: end), now: now)
        let trends = trends(samples)
        return UsageChartModel(metric: metric, window: DateInterval(start: start, end: end),
                               samples: samples, lines: lines(samples), trends: trends,
                               projection: metric == .session ? projection(samples: samples, trends: trends, end: end, now: now) : nil,
                               now: now)
    }

    /// A window starts at 0% with the first message, so that's a known point even before we
    /// saw anything.
    static func samples(points: [UsagePoint], metric: UsageMetric, window: DateInterval,
                        now: Date) -> [UsageSample] {
        var samples = [UsageSample(date: window.start, value: 0)]
        for point in points where point.date > window.start && point.date < window.end && point.date <= now {
            // Points from another window (or "not started", which can't be true inside one).
            guard let value = point.utilization(metric), let reset = point.resetsAt(metric),
                  abs(reset.timeIntervalSince(window.end)) < UsageHistory.resetTolerance else { continue }
            samples.append(UsageSample(date: point.date, value: value))
        }
        if let last = samples.last, now > last.date, now < window.end {
            samples.append(UsageSample(date: now, value: last.value))
        }
        return samples
    }

    /// Splits the samples into watched and unwatched runs, so the chart can draw stretches
    /// we didn't see differently instead of pretending the line between them is known.
    static func lines(_ samples: [UsageSample]) -> [UsageLine] {
        var lines: [UsageLine] = []
        var run: [UsageSample] = []
        var watched = true
        for (a, b) in zip(samples, samples.dropFirst()) {
            let edgeWatched = b.date.timeIntervalSince(a.date) <= gapThreshold
            if run.isEmpty {
                run = [a, b]
                watched = edgeWatched
            } else if edgeWatched == watched {
                run.append(b)
            } else {
                lines.append(UsageLine(id: lines.count, watched: watched, samples: run))
                run = [a, b]
                watched = edgeWatched
            }
        }
        if !run.isEmpty { lines.append(UsageLine(id: lines.count, watched: watched, samples: run)) }
        return lines
    }

    /// Stretches of active use: the percentage keeps going up with no pause longer than
    /// `idleBreak`. Each gets a least-squares line, whose slope is the burn rate.
    static func trends(_ samples: [UsageSample]) -> [TrendLine] {
        var result: [TrendLine] = []
        var i = 0
        while i + 1 < samples.count {
            guard samples[i + 1].value > samples[i].value else { i += 1; continue }
            // If the rise happened while nobody watched, its start time is unknown: begin after it.
            var first = i
            if samples[i + 1].date.timeIntervalSince(samples[i].date) > gapThreshold { first = i + 1 }
            var last = i + 1
            var k = i + 1
            while k + 1 < samples.count {
                let next = samples[k + 1]
                if next.date.timeIntervalSince(samples[last].date) > idleBreak
                    || next.date.timeIntervalSince(samples[k].date) > gapThreshold { break }
                if next.value > samples[k].value { last = k + 1 }
                k += 1
            }
            if let line = fit(Array(samples[first...last])) { result.append(line) }
            i = last
        }
        return result
    }

    /// Least squares over the samples, or nil if they're too few, too short or too flat to
    /// say anything (a single 1% step isn't a rate).
    static func fit(_ samples: [UsageSample]) -> TrendLine? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2,
              last.date.timeIntervalSince(first.date) >= 3 * 60,
              last.value - first.value >= 2 else { return nil }
        let xs = samples.map { $0.date.timeIntervalSince(first.date) / 3600 }
        let ys = samples.map(\.value)
        let n = Double(samples.count)
        let meanX = xs.reduce(0, +) / n, meanY = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            sxy += (x - meanX) * (y - meanY)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        let intercept = meanY - slope * meanX
        return TrendLine(start: UsageSample(date: first.date, value: max(0, intercept)),
                         end: UsageSample(date: last.date, value: max(0, intercept + slope * xs[xs.count - 1])),
                         perHour: slope)
    }

    /// Continues the latest stretch of use from the current value, if it's still going.
    static func projection(samples: [UsageSample], trends: [TrendLine], end: Date, now: Date) -> Projection? {
        guard let trend = trends.last, let current = samples.last,
              now.timeIntervalSince(trend.end.date) <= idleBreak,
              trend.perHour >= 1, current.value < 100, now < end else { return nil }
        let from = UsageSample(date: now, value: current.value)
        let perSecond = trend.perHour / 3600
        let hit = now.addingTimeInterval((100 - current.value) / perSecond)
        if hit < end {
            return Projection(from: from, to: UsageSample(date: hit, value: 100), perHour: trend.perHour, hitsLimit: true)
        }
        let atReset = current.value + perSecond * end.timeIntervalSince(now)
        return Projection(from: from, to: UsageSample(date: end, value: atReset), perHour: trend.perHour, hitsLimit: false)
    }

    /// The charted value at `date` (linear between samples), for the hover readout.
    func value(at date: Date) -> Double? {
        guard let first = samples.first, let last = samples.last,
              date >= first.date, date <= last.date else { return nil }
        guard let upper = samples.firstIndex(where: { $0.date >= date }) else { return last.value }
        if upper == 0 { return first.value }
        let a = samples[upper - 1], b = samples[upper]
        let span = b.date.timeIntervalSince(a.date)
        guard span > 0 else { return b.value }
        return a.value + (b.value - a.value) * date.timeIntervalSince(a.date) / span
    }
}
