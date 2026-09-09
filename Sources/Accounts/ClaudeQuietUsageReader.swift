import Foundation

protocol ClaudeAccountReading {
    func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState
}

/// Reads the same endpoint as Claude's usage page, without starting Claude or
/// its interactive `security` helper. Expired subscriptions renew natively without prompts.
actor ClaudeQuietUsageReader: ClaudeAccountReading {
    private let credentials: ClaudeSystemCredentials
    private let session: URLSession
    private let now: () -> Date
    private var retryAfter: [String: Date] = [:]
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    init(credentials: ClaudeSystemCredentials, session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: configuration)
    }

    func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw ManagedAccountError.cancelled }
        if let until = retryAfter[location.service], until > now() {
            throw UsageProviderError.rateLimited(retryAfter: until.timeIntervalSince(now()))
        }
        let credentials = self.credentials
        let login = try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .utility) {
                try credentials.subscriptionLogin(at: location, cancellation: cancellation)
            }.value
        }, onCancel: { cancellation.cancel() })
        guard !cancellation.isCancelled, !Task.isCancelled else { throw ManagedAccountError.cancelled }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        // Never forward a subscription token to a redirect target.
        let (data, response) = try await session.data(for: request, delegate: RejectRedirects())
        guard !cancellation.isCancelled, !Task.isCancelled else { throw ManagedAccountError.cancelled }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 {
            let delay = max(60, ClaudeOAuthProvider.retryAfter(from: response) ?? 60)
            retryAfter[location.service] = now().addingTimeInterval(delay)
            throw UsageProviderError.rateLimited(retryAfter: delay)
        }
        if status == 401 || status == 403 { throw ClaudeSystemCredentialError.expiredLogin }
        guard status == 200, data.count <= 1_048_576 else { throw ManagedAccountError.invalidResponse }
        let rates = try AccountQuotas.json(data)
        let wrapped = try JSONSerialization.data(withJSONObject: ["rate_limits_available": true, "rate_limits": rates])
        let state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true,
            email: login.identity.email, plan: login.plan), usage: wrapped, now: now())
        guard state.isFresh(at: now()) else { throw ManagedAccountError.invalidResponse }
        retryAfter.removeValue(forKey: location.service)
        return state
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
