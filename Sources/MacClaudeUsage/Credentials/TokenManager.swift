import Foundation
import CryptoKit

enum AuthError: Error, LocalizedError {
    case notSignedIn
    /// The refresh token was rejected — only a new `/login` in Claude Code can fix this.
    case signInExpired
    case refreshFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Claude Code. Run `claude` and sign in."
        case .signInExpired:
            return "Claude Code sign-in expired. Run `claude` and use /login."
        case .refreshFailed(let detail):
            return "Couldn't refresh the token: \(detail)"
        case .busy:
            return "Another process is refreshing the token; will retry."
        }
    }
}

/// Supplies a valid OAuth access token from Claude Code's Keychain item, refreshing it
/// when needed.
///
/// Why the old approach kept breaking: Anthropic's refresh tokens are single-use (rotating).
/// A reader that never refreshes goes stale after a few hours unless Claude Code happens to
/// run; a reader that refreshes into its *own* storage kills Claude Code's copy of the
/// refresh token. The only safe way to share one login is to behave exactly like another
/// Claude Code process:
///
/// 1. Take Claude Code's refresh lock (`~/.claude/.oauth_refresh.lock` + `~/.claude.lock`).
/// 2. Re-read the Keychain under the lock; if another process already refreshed, use that.
/// 3. Otherwise refresh with the same client/scopes Claude Code uses.
/// 4. Compare-and-swap the result back into the *same* Keychain item under Claude Code's
///    storage write lock, keeping every other field intact.
///
/// Running Claude Code processes re-read the Keychain before their own refresh and on any
/// 401, so they pick up our new token seamlessly.
actor TokenManager {
    private enum OAuth {
        static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
        static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        /// Scopes Claude Code requests on refresh for its default client.
        static let baseScopes = ["user:profile", "user:inference", "user:sessions:claude_code",
                                 "user:mcp_servers", "user:file_upload"]
        /// Optional scopes Claude Code carries over from the stored grant.
        static let expansionScopes: Set<String> = ["user:projects:read", "user:projects:write",
                                                   "user:plugins"]
    }

    private let keychain: ClaudeKeychain
    private let session: URLSession
    private let claudeDir: String
    /// Hashes of refresh tokens the server rejected, so we don't hammer it with dead ones.
    private var deadRefreshTokens: Set<String> = []
    /// Tokens we obtained but failed to persist — better than nothing until the next login.
    private var unsavedAccessToken: (token: String, expiresAt: Date)?

    init(keychain: ClaudeKeychain = ClaudeKeychain(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeDir = (home as NSString).appendingPathComponent(".claude")
    }

    /// Returns an access token that is valid for at least a few more minutes.
    func accessToken() async throws -> String {
        let creds = try readCredentials()
        guard let token = creds.accessToken else { throw AuthError.notSignedIn }
        if let expiry = creds.expiresAt {
            Log.auth.info("Token expires \(expiry, privacy: .public) (in \(Int(expiry.timeIntervalSinceNow / 60), privacy: .public) min)")
        }
        if !creds.needsRefresh() { return token }
        Log.auth.info("Access token expires soon; refreshing")
        return try await refresh(rejectedToken: token, force: false)
    }

    /// Called after the API rejected `token` with 401.
    func recover(fromRejected token: String) async throws -> String {
        let creds = try readCredentials()
        if let current = creds.accessToken, current != token {
            Log.auth.info("401 recovered: Keychain already has a newer token")
            return current
        }
        Log.auth.info("401 with current token; forcing refresh")
        return try await refresh(rejectedToken: token, force: true)
    }

    func subscriptionType() -> String? {
        try? readCredentials().subscriptionType
    }

    // MARK: - Reading

    private func readCredentials() throws -> ClaudeCredentials {
        do {
            return try ClaudeCredentials(json: keychain.read())
        } catch KeychainError.notFound {
            throw AuthError.notSignedIn
        }
    }

    // MARK: - Refresh

    private func refresh(rejectedToken: String, force: Bool) async throws -> String {
        if let unsaved = unsavedAccessToken, unsaved.token != rejectedToken,
           unsaved.expiresAt > Date().addingTimeInterval(60) {
            return unsaved.token
        }
        for attempt in 0..<8 {
            if let locks = acquireRefreshLocks() {
                defer { locks.forEach { $0.release() } }
                return try await refreshLocked(rejectedToken: rejectedToken, force: force)
            }
            // Someone (probably Claude Code) is refreshing right now. Wait and see.
            Log.auth.info("Refresh lock busy (attempt \(attempt + 1)); waiting")
            try await Task.sleep(for: .milliseconds(1000 + Int.random(in: 0...1000) + attempt * 250))
            let creds = try readCredentials()
            if let token = creds.accessToken, token != rejectedToken, !creds.needsRefresh() {
                return token
            }
        }
        throw AuthError.busy
    }

    /// Takes Claude Code's refresh lock and its legacy lock, in the same order it does.
    private func acquireRefreshLocks() -> [DirectoryLock]? {
        try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let primaryPath = (claudeDir as NSString).appendingPathComponent(".oauth_refresh.lock")
        guard let primary = DirectoryLock.tryAcquire(primaryPath, stale: 60) else { return nil }
        let realDir = (claudeDir as NSString).resolvingSymlinksInPath
        guard let legacy = DirectoryLock.tryAcquire(realDir + ".lock", stale: 60) else {
            primary.release()
            return nil
        }
        return [primary, legacy]
    }

    private func refreshLocked(rejectedToken: String, force: Bool) async throws -> String {
        let creds = try readCredentials()
        guard let current = creds.accessToken else { throw AuthError.notSignedIn }
        // Another process refreshed while we were waiting for the lock.
        if current != rejectedToken {
            Log.auth.info("Another process refreshed first; using its token")
            return current
        }
        if !force && !creds.needsRefresh() { return current }
        guard let refreshToken = creds.refreshToken else { throw AuthError.signInExpired }
        if deadRefreshTokens.contains(Self.fingerprint(refreshToken)) { throw AuthError.signInExpired }

        let isDefaultClient = creds.clientId == nil
            && (creds.scopes.contains("user:inference") || creds.subscriptionType != nil)
        let requested = isDefaultClient
            ? Self.unique(OAuth.baseScopes + creds.scopes.filter(OAuth.expansionScopes.contains))
            : creds.scopes

        let tokens: RefreshedTokens
        do {
            tokens = try await postRefresh(refreshToken: refreshToken, scopes: requested,
                                           clientId: creds.clientId)
        } catch RefreshHTTPError.invalidScope where isDefaultClient && !creds.scopes.isEmpty {
            tokens = try await postRefresh(refreshToken: refreshToken, scopes: creds.scopes,
                                           clientId: creds.clientId)
        } catch RefreshHTTPError.invalidGrant {
            // Maybe a sibling rotated it just now; otherwise the login is truly gone.
            if let latest = try? readCredentials(), let token = latest.accessToken,
               token != rejectedToken {
                return token
            }
            deadRefreshTokens.insert(Self.fingerprint(refreshToken))
            Log.auth.error("Refresh token rejected (invalid_grant); sign-in needed")
            throw AuthError.signInExpired
        } catch let error as RefreshHTTPError {
            Log.auth.error("Refresh failed: \(error.description, privacy: .public)")
            throw AuthError.refreshFailed(error.description)
        }
        Log.auth.info("Refreshed token; new expiry \(tokens.expiresAt, privacy: .public)")

        return try save(tokens, postedRefreshToken: refreshToken)
    }

    /// Compare-and-swap into Claude Code's item under its storage write lock.
    private func save(_ tokens: RefreshedTokens, postedRefreshToken: String) throws -> String {
        let lockPath = (claudeDir as NSString).appendingPathComponent(".storage-write.lock")
        for attempt in 0..<3 {
            var lock: DirectoryLock?
            for _ in 0..<20 {
                lock = DirectoryLock.tryAcquire(lockPath, stale: 15)
                if lock != nil { break }
                Thread.sleep(forTimeInterval: 0.1 + Double(attempt) * 0.1)
            }
            guard let lock else { continue }
            defer { lock.release() }

            do {
                var latest = try readCredentials()
                guard latest.hasOAuth else {
                    // Logged out while we were refreshing — don't resurrect the login.
                    unsavedAccessToken = (tokens.accessToken, tokens.expiresAt)
                    return tokens.accessToken
                }
                if let stored = latest.refreshToken, stored != postedRefreshToken,
                   let token = latest.accessToken {
                    // A sibling saved newer tokens meanwhile; adopt theirs, like Claude Code.
                    Log.auth.info("Keychain changed during refresh; adopting sibling's tokens")
                    return token
                }
                latest.apply(tokens)
                try keychain.write(latest.jsonData())
                // Verify the write landed before trusting it.
                if (try? readCredentials())?.accessToken == tokens.accessToken {
                    unsavedAccessToken = nil
                    Log.auth.info("Saved refreshed tokens to Claude Code's Keychain item")
                    return tokens.accessToken
                }
                Log.auth.error("Keychain write did not verify (attempt \(attempt + 1))")
            } catch {
                Log.auth.error("Keychain save failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
        }
        Log.auth.fault("Could not persist refreshed tokens; keeping them in memory")
        // The old refresh token is already spent; keep the new access token in memory so
        // at least this app keeps working until it expires.
        unsavedAccessToken = (tokens.accessToken, tokens.expiresAt)
        return tokens.accessToken
    }

    // MARK: - HTTP

    private enum RefreshHTTPError: Error, CustomStringConvertible {
        case invalidGrant
        case invalidScope
        case status(Int, String)
        case transport(String)

        var description: String {
            switch self {
            case .invalidGrant: return "invalid_grant"
            case .invalidScope: return "invalid_scope"
            case .status(let code, let error): return "HTTP \(code) \(error)"
            case .transport(let message): return message
            }
        }
    }

    private func postRefresh(refreshToken: String, scopes: [String],
                             clientId: String?) async throws -> RefreshedTokens {
        var request = URLRequest(url: OAuth.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId ?? OAuth.clientID,
            "scope": scopes.joined(separator: " ")
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshHTTPError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard status == 200 else {
            let code = (json["error"] as? String)
                ?? ((json["error"] as? [String: Any])?["type"] as? String) ?? ""
            if (status == 400 || status == 401) && code == "invalid_grant" { throw RefreshHTTPError.invalidGrant }
            if status == 400 && code == "invalid_scope" { throw RefreshHTTPError.invalidScope }
            throw RefreshHTTPError.status(status, code)
        }
        guard let access = json["access_token"] as? String,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw RefreshHTTPError.status(status, "malformed response")
        }
        let now = Date()
        let grantedScopes = (json["scope"] as? String)?
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return RefreshedTokens(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? refreshToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            refreshTokenExpiresAt: (json["refresh_token_expires_in"] as? NSNumber)
                .map { now.addingTimeInterval($0.doubleValue) },
            scopes: grantedScopes?.isEmpty == false ? grantedScopes! : scopes
        )
    }

    // MARK: - Helpers

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
