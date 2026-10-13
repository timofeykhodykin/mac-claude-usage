import Charts
import SwiftUI

/// The chart block in the dropdown: a Session / Week switch, the chart of the current window,
/// and a one-line reading of it.
struct UsageChartSection: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.chartMetric) private var metric: UsageMetric = .session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Over time").font(.subheadline.weight(.medium))
                Spacer()
                Picker("Chart", selection: $metric) {
                    Text("Session").tag(UsageMetric.session)
                    Text("Week").tag(UsageMetric.weekly)
                }
                .pickerStyle(.segmented)
                .tint(.claude)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let window = metric == .session ? store.snapshot?.session : store.snapshot?.weekly
                if let model = UsageChartModel.make(points: store.history, metric: metric,
                                                    resetsAt: window?.resetsAt, now: context.date) {
                    VStack(alignment: .leading, spacing: 6) {
                        UsageChart(model: model)
                        if let caption = UsageChart.caption(model) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text(window == nil ? "No data yet" : "Starts with your next message")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: UsageChart.height)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                }
            }
        }
    }
}

struct UsageChart: View {
    let model: UsageChartModel
    @State private var hoverDate: Date?
    @Environment(\.colorScheme) private var colorScheme

    static let height: CGFloat = 112

    private var lineColor: Color { .claude }

    /// Neutral ink for the fitted lines: they're a reading of the data, not more data.
    private var trendColor: Color { Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.14) }

    private var surface: Color { Color(nsColor: .windowBackgroundColor) }

    var body: some View {
        Chart {
            if model.metric == .weekly {
                // Even pace: the whole limit spread evenly over the week.
                ForEach([UsageSample(date: model.window.start, value: 0),
                         UsageSample(date: model.window.end, value: 100)], id: \.date) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Usage", sample.value),
                             series: .value("Line", "pace"))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }

            ForEach(Array(model.samples.enumerated()), id: \.offset) { _, sample in
                AreaMark(x: .value("Time", sample.date), y: .value("Usage", sample.value))
                    .foregroundStyle(lineColor.opacity(0.12))
            }

            // Under the usage line: a wide soft band per stretch of active use. Where usage
            // grew steadily it hugs the line; its slope is that stretch's pace.
            ForEach(Array(model.trends.enumerated()), id: \.offset) { index, trend in
                ForEach([trend.start, trend.end], id: \.date) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Usage", sample.value),
                             series: .value("Line", "trend-\(index)"))
                        .foregroundStyle(trendColor)
                        .lineStyle(StrokeStyle(lineWidth: 7, lineCap: .round))
                }
            }

            ForEach(model.lines) { line in
                ForEach(Array(line.samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Usage", sample.value),
                             series: .value("Line", "usage-\(line.id)"))
                        // Not watched: we only know both ends, so draw it faint.
                        .foregroundStyle(line.watched ? lineColor : lineColor.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: line.watched ? 2 : 1.5, lineCap: .round, lineJoin: .round))
                }
            }

            if let projection = model.projection {
                ForEach([projection.from, projection.to], id: \.date) { sample in
                    LineMark(x: .value("Time", sample.date), y: .value("Usage", sample.value),
                             series: .value("Line", "projection"))
                        .foregroundStyle(lineColor.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
                }
            }

            RuleMark(x: .value("Now", model.now))
                .foregroundStyle(Color.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))

            if let current = model.current {
                // A surface-colored ring keeps the end dot legible on top of the lines.
                PointMark(x: .value("Time", current.date), y: .value("Usage", current.value))
                    .foregroundStyle(surface)
                    .symbolSize(110)
                PointMark(x: .value("Time", current.date), y: .value("Usage", current.value))
                    .foregroundStyle(lineColor)
                    .symbolSize(50)
            }

            if let hoverDate, let readout = readout(at: hoverDate) {
                RuleMark(x: .value("Time", hoverDate))
                    .foregroundStyle(Color.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", hoverDate), y: .value("Usage", readout.value))
                    .foregroundStyle(lineColor)
                    .symbolSize(36)
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text(readout.text)
                            .font(.caption2.monospacedDigit())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.background))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                    }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: model.window.start...model.window.end)
        .chartYScale(domain: 0...max(100, model.samples.map(\.value).max() ?? 0))
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let percent = value.as(Double.self) { Text("\(Int(percent))%") }
                }
                .font(.caption2)
                .foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            switch model.metric {
            case .session:
                AxisMarks(values: Self.hourMarks(in: model.window)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour(), anchor: .top)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            case .weekly:
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        .font(.caption2)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            hoverDate = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .frame(height: Self.height)
        .help(helpText)
        .accessibilityElement()
        .accessibilityLabel(model.metric == .session ? "Session usage over time" : "Weekly usage over time")
        .accessibilityValue(Self.caption(model) ?? "")
    }

    /// Whole hours inside the window, minus ones so close to an edge that the label would
    /// be clipped.
    static func hourMarks(in window: DateInterval, calendar: Calendar = .current) -> [Date] {
        let margin: TimeInterval = 30 * 60
        guard var hour = calendar.dateInterval(of: .hour, for: window.start)?.end else { return [] }
        var marks: [Date] = []
        while hour < window.end.addingTimeInterval(-margin) {
            if hour >= window.start.addingTimeInterval(margin) { marks.append(hour) }
            hour = hour.addingTimeInterval(3600)
        }
        return marks
    }

    private var helpText: String {
        var parts = ["Line: your usage. Faint where nobody was watching (Mac asleep or app closed).",
                     "Gray band: straight-line fit of each stretch of active use. Hover for its pace."]
        switch model.metric {
        case .session: parts.append("Dashed color: where the current pace leads.")
        case .weekly: parts.append("Thin diagonal: even pace through the week.")
        }
        return parts.joined(separator: "\n")
    }

    private func readout(at date: Date) -> (value: Double, text: String)? {
        let time = model.metric == .session
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        if let value = model.value(at: date) {
            let pace = model.trends.first { $0.start.date <= date && date <= $0.end.date }
            return (value, "\(time) · \(Int(value.rounded()))%" + (pace.map { " · \(Self.rate($0.perHour))" } ?? ""))
        }
        if let projection = model.projection, date > projection.from.date, date <= projection.to.date {
            let span = projection.to.date.timeIntervalSince(projection.from.date)
            let value = projection.from.value
                + (projection.to.value - projection.from.value) * date.timeIntervalSince(projection.from.date) / span
            return (value, "\(time) · ≈ \(Int(value.rounded()))% at this pace")
        }
        return nil
    }

    // MARK: - Text

    /// One line that says what the chart means right now.
    static func caption(_ model: UsageChartModel,
                        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String? {
        switch model.metric {
        case .session:
            if let projection = model.projection {
                return projection.hitsLimit
                    ? "At \(rate(projection.perHour)) you'd hit the limit at \(time(projection.to.date))"
                    : "At \(rate(projection.perHour)): ≈ \(Int(projection.to.value.rounded()))% by the reset"
            }
            if let last = model.trends.last {
                return "Last active stretch: \(rate(last.perHour))"
            }
            return nil
        case .weekly:
            guard let current = model.current else { return nil }
            let elapsed = model.now.timeIntervalSince(model.window.start) / model.window.duration
            return "\(Int(current.value.rounded()))% used · \(Int((elapsed * 100).rounded()))% of the week has passed"
        }
    }

    /// `18%/h`, `2.5%/h`.
    static func rate(_ perHour: Double) -> String {
        perHour >= 10 ? "\(Int(perHour.rounded()))%/h" : String(format: "%.1f%%/h", perHour)
    }
}

enum SessionsLabel {
    /// `≈ 2.9 ± 0.3 of 7.4 ± 0.8 full sessions left`: full 5-hour sessions that fit in the
    /// rest of the week, with a ~95% range. A range while the data is thin, nothing while
    /// it can't say much yet (the rough range is in the tooltip).
    static func text(_ estimate: SessionsEstimate?) -> String {
        guard let estimate else { return "Sessions left: learning from your usage…" }
        let left = estimate.remaining, week = estimate.perWeek
        if let leftValue = left.value, let weekValue = week.value, estimate.relativeError <= 0.35 {
            let e = estimate.relativeError
            return "≈ \(number(leftValue)) ± \(error(leftValue * e)) of \(number(weekValue)) ± \(error(weekValue * e)) full sessions left"
        }
        if let leftHigh = left.high, let weekHigh = week.high, estimate.relativeError <= 0.5 {
            return "\(number(left.low))–\(number(leftHigh)) of \(number(week.low))–\(number(weekHigh)) full sessions left"
        }
        return "Sessions left: estimating, needs a bit more use…"
    }

    /// `2.1–24`, or `at least 3.7` when the data can't rule out "practically unlimited".
    static func rough(_ bounds: SessionsEstimate.Bounds) -> String {
        bounds.high.map { "\(number(bounds.low))–\(number($0))" } ?? "at least \(number(bounds.low))"
    }

    static func help(_ estimate: SessionsEstimate?) -> String {
        var lines = ["Full 5-hour sessions (0 → 100% of the session limit) that fit in what's left of the weekly limit, and in a whole week."]
        guard let estimate else {
            lines.append("Learned from how much the weekly limit grows as the session limit does; shows up once you've used some of a session.")
            return lines.joined(separator: "\n")
        }
        let day = { (date: Date) in date.formatted(.dateTime.day().month(.abbreviated)) }
        let sessions = estimate.sessions == 1 ? "1 session" : "\(estimate.sessions) sessions"
        lines.append("Learned from how much the weekly limit grew in \(sessions) since \(day(estimate.since)); recent days count more. ± and ranges cover ~95%.")
        if estimate.relativeError > 0.5 {
            lines.append("So far: \(rough(estimate.remaining)) of \(rough(estimate.perWeek)) full sessions left. The weekly limit has to move a few more points to narrow this down.")
        }
        if let changed = estimate.limitsChangedAt {
            lines.append("The limits seem to have changed around \(day(changed)), so older data is ignored.")
        }
        return lines.joined(separator: "\n")
    }

    private static func number(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))" : String(format: "%.1f", value)
    }

    /// Rounded up, so it never reads `± 0.0`.
    private static func error(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded(.up)))" : String(format: "%.1f", max(0.1, (value * 10).rounded(.up) / 10))
    }
}

extension Color {
    /// Claude's terracotta, one step darker on light backgrounds and lighter on dark ones so
    /// thin lines and small controls keep ≥ 3:1 contrast either way.
    static let claude = Color(nsColor: NSColor(name: "claude") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.91, green: 0.53, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.38, blue: 0.25, alpha: 1)
    })
}
