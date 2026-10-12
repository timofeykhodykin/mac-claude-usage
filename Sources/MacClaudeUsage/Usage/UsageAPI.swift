import Foundation

struct UsageWindow: Codable, Equatable {
    /// 0…100
    var utilization: Double
    var resetsAt: Date?

    /// Once the reset time has passed, the window starts over at 0 — true even if we
    /// couldn't fetch anything since.
    func hasReset(now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    func currentUtilization(now: Date = Date()) -> Double {
        hasReset(now: now) ? 0 : utilization
    }
}

enum UsageSource: String, Codable {
    /// Polled `api/oauth/usage`.
    case api
    /// Pushed by Claude Code through the status-line command.
    case statusLine
    /// Claude Code's cached `/usage` result in `~/.claude.json`.
    case claudeCache
}

struct UsageSnapshot: Codable, Equatable {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var fetchedAt: Date
    var source: UsageSource? = .api
}

enum UsageError: Error, LocalizedError {
    case auth(AuthError)
    case keychain(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .auth(let error): return error.localizedDescription
        case .keychain(let message): return message
        case .rateLimited: return "Rate limited by Anthropic; backing off."
        case .http(let code): return "Usage request failed (HTTP \(code))."
        case .network(let message): return "Network error: \(message)"
        case .decoding: return "Unexpected response from the usage endpoint."
        }
    }

    /// Errors that need the user to act (sign in again), as opposed to transient ones.
    var needsUserAction: Bool {
        if case .auth(let error) = self {
            switch error {
            case .notSignedIn, .signInExpired: return true
            default: return false
            }
        }
        return false
    }
}

/// `GET https://api.anthropic.com/api/oauth/usage` — the endpoint Claude Code's `/usage` uses.
struct UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let tokens: TokenManager
    var session: URLSession = .shared

    func fetch() async throws -> UsageSnapshot {
        let token: String
        do {
            token = try await tokens.accessToken()
        } catch let error as AuthError {
            throw UsageError.auth(error)
        } catch {
            throw UsageError.keychain(error.localizedDescription)
        }

        let (status, data, response) = try await get(token: token)
        switch status {
        case 200:
            return try Self.parse(data)
        case 401:
            // Token revoked early or rotated by someone else — recover once.
            let fresh: String
            do {
                fresh = try await tokens.recover(fromRejected: token)
            } catch let error as AuthError {
                throw UsageError.auth(error)
            } catch {
                throw UsageError.keychain(error.localizedDescription)
            }
            let (retryStatus, retryData, retryResponse) = try await get(token: fresh)
            if retryStatus == 200 { return try Self.parse(retryData) }
            throw Self.error(for: retryStatus, response: retryResponse, body: retryData)
        default:
            throw Self.error(for: status, response: response, body: data)
        }
    }

    private func get(token: String) async throws -> (Int, Data, HTTPURLResponse?) {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            return (http?.statusCode ?? 0, data, http)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
    }

    private static func error(for status: Int, response: HTTPURLResponse?, body: Data) -> UsageError {
        if status != 200 {
            let text = String(data: body.prefix(400), encoding: .utf8) ?? ""
            let headers = (response?.allHeaderFields ?? [:])
                .compactMap { key, value -> String? in
                    let name = "\(key)".lowercased()
                    guard name.hasPrefix("retry") || name.contains("ratelimit") || name == "request-id" else { return nil }
                    return "\(name)=\(value)"
                }
                .sorted().joined(separator: " ")
            Log.usage.error("HTTP \(status, privacy: .public) body: \(text, privacy: .public) headers: \(headers, privacy: .public)")
        }
        switch status {
        case 429:
            let header = response?.value(forHTTPHeaderField: "Retry-After")
            Log.usage.info("429 Retry-After: \(header ?? "none", privacy: .public)")
            return .rateLimited(retryAfter: parseRetryAfter(header))
        case 401:
            return .auth(.signInExpired)
        default:
            return .http(status)
        }
    }

    // MARK: - Parsing

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private struct Response: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        struct Limit: Decodable {
            let kind: String?
            let percent: Double?
            let resets_at: String?
        }
        let five_hour: Window?
        let seven_day: Window?
        let limits: [Limit]?
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw UsageError.decoding
        }
        func window(_ w: Response.Window?, fallbackKind: String) -> UsageWindow? {
            if let w, let utilization = w.utilization {
                return UsageWindow(utilization: utilization, resetsAt: parseDate(w.resets_at))
            }
            // Newer response shape: `limits: [{ kind: "session" | "weekly_all", percent, … }]`.
            if let limit = response.limits?.first(where: { $0.kind == fallbackKind }),
               let percent = limit.percent {
                return UsageWindow(utilization: percent, resetsAt: parseDate(limit.resets_at))
            }
            return nil
        }
        return UsageSnapshot(session: window(response.five_hour, fallbackKind: "session"),
                             weekly: window(response.seven_day, fallbackKind: "weekly_all"),
                             fetchedAt: now, source: .api)
    }

    /// Handles `2026-06-11T18:00:00.308440+00:00` (microseconds) as well as plain timestamps.
    static func parseDate(_ raw: String?) -> Date? {
        guard var raw, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        // Trim fractional seconds to milliseconds, which ISO8601DateFormatter understands.
        if let dot = raw.firstIndex(of: ".") {
            let fractionEnd = raw[dot...].dropFirst().firstIndex { !$0.isNumber } ?? raw.endIndex
            let digits = raw[raw.index(after: dot)..<fractionEnd]
            raw.replaceSubrange(raw.index(after: dot)..<fractionEnd, with: String(digits.prefix(3)))
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
