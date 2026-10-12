import Foundation

/// Claude Code's Keychain blob, kept as a raw JSON dictionary so that writing it back never
/// drops fields this app doesn't know about (`mcpOAuth`, `designOauth`, …).
///
/// ```json
/// { "claudeAiOauth": { "accessToken": "…", "refreshToken": "…", "expiresAt": 1781211869970,
///                      "scopes": ["user:inference", …], "subscriptionType": "max", … },
///   "mcpOAuth": { … } }
/// ```
struct ClaudeCredentials {
    private(set) var root: [String: Any]

    init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw KeychainError.badData
        }
        self.root = root
    }

    private var oauth: [String: Any]? { root["claudeAiOauth"] as? [String: Any] }
    var hasOAuth: Bool { oauth != nil }

    var accessToken: String? { (oauth?["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var refreshToken: String? { (oauth?["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var scopes: [String] { oauth?["scopes"] as? [String] ?? [] }
    var clientId: String? { oauth?["clientId"] as? String }
    var subscriptionType: String? { oauth?["subscriptionType"] as? String }

    var expiresAt: Date? {
        guard let ms = (oauth?["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Claude Code refreshes when the token has less than 5 minutes left; we use the same
    /// threshold so we never refresh earlier than Claude Code itself would.
    static let refreshMargin: TimeInterval = 5 * 60

    func needsRefresh(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(Self.refreshMargin) >= expiresAt
    }

    /// Applies a token-endpoint response the same way Claude Code merges it.
    mutating func apply(_ tokens: RefreshedTokens) {
        var o = oauth ?? [:]
        o["accessToken"] = tokens.accessToken
        o["refreshToken"] = tokens.refreshToken
        o["expiresAt"] = Int64(tokens.expiresAt.timeIntervalSince1970 * 1000)
        if let refreshExpiry = tokens.refreshTokenExpiresAt {
            o["refreshTokenExpiresAt"] = Int64(refreshExpiry.timeIntervalSince1970 * 1000)
        }
        o["scopes"] = tokens.scopes
        root["claudeAiOauth"] = o
    }

    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }
}

struct RefreshedTokens {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let refreshTokenExpiresAt: Date?
    let scopes: [String]
}
