import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore
    @AppStorage(SettingsKey.icon) private var icon: MenuIcon = .claude
    @AppStorage(SettingsKey.showWeekly) private var showWeekly = false

    var body: some View {
        let text = Self.text(snapshot: store.snapshot, showWeekly: showWeekly, unavailable: store.isUnavailable)
        Image(nsImage: MenuBarImage.render(icon: icon, text: text))
            .accessibilityLabel(showWeekly ? "Claude session / weekly usage \(text)" : "Claude session usage \(text)")
    }

    /// `13%`, or `13% / 5%` (session / weekly) with `showWeekly`. `?` replaces each
    /// percentage while usage can't be fetched.
    static func text(snapshot: UsageSnapshot?, showWeekly: Bool, unavailable: Bool, now: Date = Date()) -> String {
        func percent(_ window: UsageWindow?) -> String {
            if unavailable { return "?" }
            guard let window else { return "–%" }
            return "\(Int(window.currentUtilization(now: now).rounded()))%"
        }
        let session = percent(snapshot?.session)
        return showWeekly ? "\(session) / \(percent(snapshot?.weekly))" : session
    }
}

struct MenuContentView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.showChart) private var showChart = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Claude Usage").font(.headline)
                Spacer()
                if let plan = store.plan {
                    Text(plan.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            UsageRow(title: "Session (5h)", window: store.snapshot?.session, style: .relative)
            UsageRow(title: "Weekly", window: store.snapshot?.weekly, style: .absolute,
                     note: store.snapshot?.weekly == nil ? nil : SessionsLabel.text(store.sessionsEstimate),
                     noteHelp: SessionsLabel.help(store.sessionsEstimate))

            if showChart {
                UsageChartSection(store: store)
            }

            if let until = store.backoffUntil, until > Date(), !store.isDataFresh {
                Label("Rate limited — next automatic try at \(until.formatted(date: .omitted, time: .shortened)). Showing last data.",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = store.lastError {
                Label(error.localizedDescription,
                      systemImage: error.needsUserAction ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(error.needsUserAction ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 10) {
                UpdatedLabel(date: store.snapshot?.fetchedAt, source: store.snapshot?.source)
                Spacer()
                Button {
                    store.refreshNow()
                } label: {
                    // The symbol's own rotation effect turns it around the circle of the arrow,
                    // not around the center of its bounding box.
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: store.isRefreshing)
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh now")

                Button {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

struct UsageRow: View {
    enum ResetStyle { case relative, absolute }

    let title: String
    let window: UsageWindow?
    let style: ResetStyle
    var note: String? = nil
    var noteHelp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(window.map { "\(Int($0.currentUtilization().rounded()))%" } ?? "–")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            UsageBar(fraction: (window?.currentUtilization() ?? 0) / 100)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(resetText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(noteHelp ?? "")
            }
        }
    }

    private func resetText(now: Date) -> String {
        guard let window else { return "No data yet" }
        // No reset time means the window hasn't started yet.
        guard let resetsAt = window.resetsAt else { return "Not started — starts with your next message" }
        if resetsAt <= now { return "Reset — starts again with your next message" }
        switch style {
        case .relative:
            let seconds = max(0, resetsAt.timeIntervalSince(now))
            let hours = Int(seconds) / 3600
            let minutes = (Int(seconds) % 3600) / 60
            return hours > 0 ? "Resets in \(hours)h \(minutes)m" : "Resets in \(minutes)m"
        case .absolute:
            return "Resets " + Self.absoluteReset(resetsAt, now: now)
        }
    }

    /// `today 18:00`, `tomorrow 18:00`, otherwise `30 Sep 18:00`.
    static func absoluteReset(_ date: Date, now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = locale
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: date)

        let startOfToday = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startOfToday, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        default:
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.locale = locale
            dayFormatter.dateFormat = "d MMM"
            return "\(dayFormatter.string(from: date)) \(time)"
        }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            // A capsule narrower than it is tall loses its rounding, so the fill is never
            // narrower than the bar's height: it slides in from the left, its right end at
            // `fraction`, and the track's shape clips the left end.
            let filled = max(0, min(1, fraction)) * geo.size.width
            let fillWidth = max(filled, geo.size.height)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(Self.color(at: fraction))
                    .frame(width: fillWidth)
                    .offset(x: filled - fillWidth)
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .animation(.easeOut(duration: 0.3), value: fraction)
    }

    /// Pastel green → yellow → peach → rose, evenly spaced over 0…100%. Picked in OKLCH at
    /// a similar lightness (0.80–0.88) and low chroma (≤ 0.09), so no end of the scale looks
    /// louder than the others; lightness drops a little towards rose to carry the urgency.
    static let pastelStops: [(r: Double, g: Double, b: Double)] = [
        (0.69, 0.89, 0.74),
        (0.91, 0.85, 0.59),
        (0.96, 0.74, 0.58),
        (0.95, 0.65, 0.65)
    ]

    /// The solid bar color for `fraction`: the point on the pastel scale at that usage.
    static func rgb(at fraction: Double) -> (r: Double, g: Double, b: Double) {
        let t = max(0, min(1, fraction)) * Double(pastelStops.count - 1)
        let i = min(Int(t), pastelStops.count - 2)
        let f = t - Double(i)
        let a = pastelStops[i], b = pastelStops[i + 1]
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }

    static func color(at fraction: Double) -> Color {
        let c = rgb(at: fraction)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

struct UpdatedLabel: View {
    let date: Date?
    let source: UsageSource?

    var body: some View {
        // Ticks every second, but only while the menu is open.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(text(now: context.date))
                .help(sourceHelp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func text(now: Date) -> String {
        guard let date else { return "Never updated" }
        let time = date.formatted(date: .omitted, time: .shortened)
        return "Updated \(time) · \(Self.age(now.timeIntervalSince(date))) ago"
    }

    /// `7s`, `1m 05s`, `12m 30s`, `1h 05m`, `2d 3h`.
    static func age(_ interval: TimeInterval) -> String {
        let s = max(0, Int(interval))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return String(format: "%dm %02ds", s / 60, s % 60)
        case ..<86400: return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
        default: return "\(s / 86400)d \((s % 86400) / 3600)h"
        }
    }

    private var sourceHelp: String {
        switch source {
        case .statusLine: return "Live from Claude Code's status line"
        case .claudeCache: return "From Claude Code's cached /usage"
        case .api, nil: return "From the Anthropic usage API"
        }
    }
}
