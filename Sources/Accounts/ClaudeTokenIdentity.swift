import Foundation
import CryptoKit

/// Who a saved subscription token really belongs to.
///
/// Claude keeps two records of a login: the secret in the Keychain, and the
/// account name in `.claude.json`. They are written separately, by whichever
/// Claude process last had a reason to, and a running session writes back the
/// name it started with. So the two disagree far more often than they should,
/// and an app that trusts the name copies the wrong secret into the wrong
/// profile. The token itself cannot lie: the service that issued it says who it
/// is for, and that answer never changes for a given token, so it is asked once
/// per token and remembered.
actor ClaudeTokenIdentityResolver {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let maximumBytes = 65_536

    private let session: URLSession
    private let now: () -> Date
    private var cache: [String: ClaudeCredentialIdentity] = [:]
    /// Tokens the service refused. A refused token is not asked about again for
    /// a while: it will either be renewed, and then it is a new token, or it is
    /// dead, and asking again only earns a rate limit.
    private var refusals: [String: (until: Date, error: Error)] = [:]
    private var inFlight: [String: Task<ClaudeCredentialIdentity, Error>] = [:]

    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
    }

    /// A short, stable name for a token that never contains the token.
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    func identity(forToken token: String) async throws -> ClaudeCredentialIdentity {
        let key = Self.fingerprint(token)
        if let known = cache[key] { return known }
        if let refusal = refusals[key], refusal.until > now() { throw refusal.error }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await self.fetch(token) }
        inFlight[key] = task
        defer { inFlight.removeValue(forKey: key) }
        do {
            let identity = try await task.value
            cache[key] = identity
            refusals.removeValue(forKey: key)
            return identity
        } catch {
            let delay: TimeInterval
            switch error {
            case ClaudeSystemCredentialError.expiredLogin: delay = 3600
            case UsageProviderError.rateLimited(let retryAfter): delay = max(60, retryAfter)
            default: delay = 60
            }
            refusals[key] = (now().addingTimeInterval(delay), error)
            throw error
        }
    }

    /// Test seam and offline seed: an owner learned some other way.
    func remember(_ identity: ClaudeCredentialIdentity, forToken token: String) {
        cache[Self.fingerprint(token)] = identity
    }

    private func fetch(_ token: String) async throws -> ClaudeCredentialIdentity {
        guard !token.isEmpty, token.utf8.count <= 16_384,
              token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw ClaudeSystemCredentialError.malformedData }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        return try Self.parse(data: data, response: response)
    }

    static func parse(data: Data, response: URLResponse) throws -> ClaudeCredentialIdentity {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            let delay = ClaudeOAuthProvider.retryAfter(from: response) ?? 60
            throw UsageProviderError.rateLimited(retryAfter: max(60, delay))
        }
        if status == 401 || status == 403 { throw ClaudeSystemCredentialError.expiredLogin }
        guard status == 200, data.count <= maximumBytes else { throw ManagedAccountError.invalidResponse }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = object["account"] as? [String: Any],
              let organization = object["organization"] as? [String: Any],
              let id = account["uuid"] as? String, !id.isEmpty,
              let org = organization["uuid"] as? String, !org.isEmpty else { throw ManagedAccountError.invalidResponse }
        let email = (account["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ClaudeCredentialIdentity(accountID: id, organizationID: org, email: email.isEmpty ? "—" : email)
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}

extension ClaudeCredentialIdentity {
    /// The `oauthAccount` object Claude expects in `.claude.json`, from nothing
    /// but what the service said. Used only when no saved profile has the full
    /// object to copy.
    var minimalOAuthAccount: [String: Any] {
        ["accountUuid": accountID, "organizationUuid": organizationID, "emailAddress": email]
    }
}
