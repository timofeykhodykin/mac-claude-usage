import AppKit
import Foundation

/// Combines three sources of usage data, cheapest first:
///
/// 1. **Claude Code's status line** (pushed after every response while you use Claude Code),
/// 2. **Claude Code's cached `/usage`** in `~/.claude.json`,
/// 3. **the usage endpoint**, polled only when the data above is older than the refresh
///    interval — that endpoint is rate-limited, so we call it as rarely as possible.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: UsageError?
    @Published private(set) var plan: String?
    /// While rate limited, automatic API polling pauses until this time.
    @Published private(set) var backoffUntil: Date?
    /// True when we have no data, or the last attempt failed and the data has gone stale.
    /// The menu bar then shows `?`; the dropdown keeps showing the last numbers.
    @Published private(set) var isUnavailable = false

    private let api: UsageAPI
    private let tokens: TokenManager
    private let defaults: UserDefaults
    private var loop: Task<Void, Never>?
    private var feedTimer: Timer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var consecutiveRateLimits = 0
    private var lastAPIAttempt: Date?
    /// Even manual refreshes don't hit a rate-limited API more often than this.
    private static let minManualSpacing: TimeInterval = 60
    private static let maxBackoff: TimeInterval = 30 * 60

    init(tokens: TokenManager = TokenManager(), defaults: UserDefaults = .standard) {
        self.tokens = tokens
        self.api = UsageAPI(tokens: tokens)
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsKey.cachedSnapshot) {
            snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        }
        if defaults.object(forKey: SettingsKey.liveStatusLine) as? Bool ?? true {
            // Also repoints the command if the app was moved.
            _ = try? StatusLineInstaller.install()
        }
        ingestLocalSources()
        watchLocalSources()
        observeWake()
        restartPolling()
        Task { plan = await tokens.subscriptionType() }
    }

    /// A static store for previews and screenshots: no polling, no Keychain, no settings changes.
    init(previewSnapshot: UsageSnapshot, plan: String?) {
        self.tokens = TokenManager()
        self.api = UsageAPI(tokens: tokens)
        self.defaults = UserDefaults(suiteName: "dev.mac-claude-usage.preview") ?? .standard
        self.snapshot = previewSnapshot
        self.plan = plan
    }

    /// Recomputes `isUnavailable`. Staleness depends on the clock, so this also runs on a timer.
    private func updateAvailability() {
        let backingOff = backoffUntil.map { $0 > Date() } ?? false
        let unavailable = snapshot == nil || ((lastError != nil || backingOff) && !isDataFresh)
        if unavailable != isUnavailable { isUnavailable = unavailable }
    }

    var refreshInterval: TimeInterval {
        let stored = defaults.integer(forKey: SettingsKey.refreshInterval)
        return TimeInterval(RefreshInterval(rawValue: stored)?.rawValue ?? RefreshInterval.twoMinutes.rawValue)
    }

    /// How old the displayed data is.
    var dataAge: TimeInterval {
        snapshot.map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
    }

    /// True when the displayed data is recent enough that a rate limit doesn't matter.
    var isDataFresh: Bool { dataAge < refreshInterval * 1.5 }

    /// Restarts the polling loop (e.g. after the interval setting changed).
    func restartPolling() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.ingestLocalSources()
                if self.dataAge >= self.refreshInterval * 0.9 {
                    await self.refresh()
                }
                try? await Task.sleep(for: .seconds(self.nextDelay()))
            }
        }
    }

    /// Manual refresh from the UI. Re-reads Claude Code's data, and asks the API unless we
    /// are rate limited and already asked within the last minute (hammering only extends it).
    func refreshNow() {
        ingestLocalSources()
        Task { await refresh(manual: true) }
    }

    // MARK: - API

    private func refresh(manual: Bool = false) async {
        guard !isRefreshing else { return }
        if let backoffUntil, backoffUntil > Date() {
            guard manual else { return }
            if let last = lastAPIAttempt, Date().timeIntervalSince(last) < Self.minManualSpacing {
                Log.usage.info("Manual refresh skipped: rate limited, last API call was under a minute ago")
                return
            }
        }
        lastAPIAttempt = Date()
        isRefreshing = true
        defer {
            isRefreshing = false
            updateAvailability()
        }

        do {
            let fresh = try await api.fetch()
            adopt(fresh)
            lastError = nil
            backoffUntil = nil
            consecutiveRateLimits = 0
            plan = await tokens.subscriptionType()
            Log.usage.info("Fetched usage: session \(fresh.session?.utilization ?? -1, privacy: .public)%, weekly \(fresh.weekly?.utilization ?? -1, privacy: .public)%")
        } catch let error as UsageError {
            Log.usage.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            lastError = error
            if case .rateLimited(let retryAfter) = error {
                // Exponential backoff (2×, 4×, 8× the interval…), never shorter than the
                // server's Retry-After, capped at 30 minutes.
                // Manual clicks don't escalate the backoff; only the automatic schedule does.
                if !manual || consecutiveRateLimits == 0 { consecutiveRateLimits += 1 }
                let exponential = refreshInterval * pow(2, Double(consecutiveRateLimits))
                let delay = min(Self.maxBackoff, max(retryAfter ?? 0, exponential, 60))
                backoffUntil = Date().addingTimeInterval(delay)
                Log.usage.info("Rate limited \(self.consecutiveRateLimits, privacy: .public)× in a row; pausing \(Int(delay), privacy: .public)s")
            }
        } catch {
            lastError = .network(error.localizedDescription)
        }
    }

    private func nextDelay() -> TimeInterval {
        if let backoffUntil, backoffUntil > Date() {
            // Keep checking local sources meanwhile; they cost nothing.
            return min(backoffUntil.timeIntervalSinceNow + 1, refreshInterval)
        }
        if let lastError {
            switch lastError {
            case .network, .http, .decoding, .keychain, .auth(.busy), .auth(.refreshFailed):
                // Transient: retry sooner than the normal interval.
                return min(refreshInterval, 30)
            default:
                break
            }
        }
        // Wake up when the current data becomes due, not a full interval from now.
        return max(15, refreshInterval - dataAge)
    }

    // MARK: - Local sources

    private func ingestLocalSources() {
        for candidate in [LiveFeed.readStatusLineFeed(), LiveFeed.readClaudeCache()].compactMap({ $0 }) {
            if let current = snapshot, candidate.fetchedAt <= current.fetchedAt { continue }
            adopt(candidate)
            // Fresh data from Claude Code supersedes a transient API error.
            if let lastError, !lastError.needsUserAction { self.lastError = nil }
            Log.usage.info("Picked up usage from \(candidate.source?.rawValue ?? "?", privacy: .public): session \(candidate.session?.utilization ?? -1, privacy: .public)%")
        }
        updateAvailability()
    }

    /// The status-line feed changes whenever Claude Code responds; reading a small file
    /// every few seconds is effectively free.
    private func watchLocalSources() {
        feedTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ingestLocalSources() }
        }
    }

    /// Takes a newer snapshot, keeping windows the new source didn't report.
    private func adopt(_ incoming: UsageSnapshot) {
        var merged = incoming
        if merged.session == nil { merged.session = snapshot?.session }
        if merged.weekly == nil { merged.weekly = snapshot?.weekly }
        snapshot = merged
        if let data = try? JSONEncoder().encode(merged) {
            defaults.set(data, forKey: SettingsKey.cachedSnapshot)
        }
    }

    /// After sleep the token has often expired and the data is stale; refresh right away
    /// (with a short delay for the network to come back).
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.restartPolling()
                }
            }
            wakeObservers.append(observer)
        }
    }
}
