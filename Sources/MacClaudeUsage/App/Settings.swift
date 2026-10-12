import Foundation

enum MenuIcon: String, CaseIterable, Identifiable {
    case claude
    case sparkle
    case sparkles
    case brain
    case bolt
    case gauge
    case flame
    case terminal
    case chart
    case none

    var id: String { rawValue }

    /// SF Symbol name, or nil for the custom-drawn Claude mark / no icon.
    var symbolName: String? {
        switch self {
        case .claude, .none: return nil
        case .sparkle: return "sparkle"
        case .sparkles: return "sparkles"
        case .brain: return "brain"
        case .bolt: return "bolt"
        case .gauge: return "gauge.with.dots.needle.67percent"
        case .flame: return "flame"
        case .terminal: return "apple.terminal"
        case .chart: return "chart.bar"
        }
    }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .none: return "None"
        default: return rawValue.capitalized
        }
    }
}

enum RefreshInterval: Int, CaseIterable, Identifiable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { rawValue }

    var title: String {
        let minutes = rawValue / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

enum SettingsKey {
    static let icon = "menuIcon"
    static let refreshInterval = "refreshInterval"
    static let cachedSnapshot = "cachedSnapshot"
    static let liveStatusLine = "liveStatusLine"
    static let showWeekly = "showWeeklyInMenuBar"
}
