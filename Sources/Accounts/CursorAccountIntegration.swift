import Foundation

/// Reads the usage of the Cursor account the **desktop editor** is signed into.
///
/// The bargain is the same one Claude Code's Keychain token makes: the editor
/// mints, refreshes and rotates this session for itself, and Builder Nutch only
/// ever borrows the current value — read-only, in memory, for the duration of a
/// single HTTPS request. Nothing is copied to disk, cached between refreshes,
/// logged, or shown. Cursor's SQLite store is opened read-only, so a running
/// editor is never blocked, and no file of Cursor's is ever written.
///
/// Because the editor owns the login, there is nothing here to rotate: this is a
/// reading, never a switch. `AccountProvider.cursor.supportsAutomaticSelection`
/// stays false for exactly that reason.
///
/// **Endpoint and response shape re-verified 10 September 2026** against the
/// maintained community reader (source commits dated 30 August 2026):
///
/// - <https://raw.githubusercontent.com/steipete/CodexBar/main/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe.swift>
/// - <https://raw.githubusercontent.com/steipete/CodexBar/main/Sources/CodexBarCore/Providers/Cursor/CursorAppAuth.swift>
///
/// `GET https://cursor.com/api/usage-summary`, the cookie
/// `WorkosCursorSessionToken=<accountID>::<accessToken>`, and the
/// `individualUsage.plan.*` fields are all unchanged since the recording pinned
/// in `CursorUsageTests`. Two things did move, and both are handled: that reader
/// no longer depends on the `cursorAuth/stripeMembershipAuthId` row at all — it
/// derives the account half from the access token's own `sub` claim, which is
/// why `CursorCredentials` now falls back to that — and its response type also
/// names `individualUsage.overall` and `teamUsage.pooled`, which a personal free
/// plan never sends. Those two are parsed defensively and fail closed: an
/// unexpected shape yields no window rather than an invented number.
enum CursorAccountIntegration {
    /// Where the editor keeps the VS Code global state it inherits.
    static func globalStorage(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
    }

    static func store(in directory: URL) -> URL {
        directory.appendingPathComponent("state.vscdb")
    }

    /// Shown on a row whose editor has since been signed out. Discovery never
    /// creates such a row in the first place; this covers a sign-out that
    /// happens after one exists.
    static let signedOutMessage = "Sign in to Cursor in the editor on this Mac, then refresh."

    /// True when the desktop editor currently holds a usable session. Reads
    /// nothing but the two rows it needs, and never retains them.
    static func isSignedIn(directory: URL = globalStorage()) -> Bool {
        (try? CursorCredentials.load(from: store(in: directory))) != nil
    }

    static func read(directory: URL, cancellation: AccountCancellation) async throws -> ManagedAccountState {
        try await read(directory: directory, cancellation: cancellation, http: CursorWebHTTP())
    }

    /// The injected `http` is what makes every failure path testable without a
    /// network, a signed-in editor, or a real token.
    static func read(directory: URL, cancellation: AccountCancellation,
                     http: any CursorHTTPFetching, now: Date = Date()) async throws -> ManagedAccountState {
        try checkCancellation(cancellation)
        let storeURL = store(in: directory)
        // Re-read on every refresh. The editor rotates this, and holding a copy
        // would mean signing ourselves out for no reason — or worse, keeping a
        // secret alive in this process long after Cursor retired it.
        guard let credentials = try? CursorCredentials.load(from: storeURL) else {
            return ManagedAccountState(message: signedOutMessage)
        }
        let identity = CursorCredentials.account(from: storeURL)

        var request = URLRequest(url: usageEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        request.setValue(credentials.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await http.fetch(request, cancellation: cancellation)
        try checkCancellation(cancellation)

        if response.statusCode == 401 || response.statusCode == 403 {
            var state = ManagedAccountState(email: identity?.label)
            state.message = "Cursor refused its own saved sign-in. Sign in again in the Cursor app, then refresh."
            state.requiresSignIn = true
            return state
        }
        guard (200..<300).contains(response.statusCode) else { throw ManagedAccountError.invalidResponse }
        return try state(usage: data, identity: identity, now: now)
    }

    static let usageEndpoint = URL(string: "https://cursor.com/api/usage-summary")!

    /// Turns one recorded response into a row. Kept separate from the transport
    /// so the pinned fixtures in `CursorUsageTests` and `CursorAccountTests`
    /// exercise exactly what the app displays.
    static func state(usage data: Data, identity: ProviderAccount?, now: Date = Date()) throws -> ManagedAccountState {
        guard data.count <= 1_048_576, let body = String(data: data, encoding: .utf8) else {
            throw ManagedAccountError.invalidResponse
        }
        var state = ManagedAccountState(isConnected: true)
        state.email = identity?.label
        state.plan = planTitle(identity?.plan)
        do {
            state.windows = try CursorUsage.windows(fromJSON: body)
            state.refreshedAt = now
        } catch UsageProviderError.nothingMetered(let explanation) {
            // Not an error, and it must not be shown as one: a plan with no
            // metered allowance is a fact about the plan, not a failure.
            state.message = explanation + "."
        } catch {
            throw ManagedAccountError.invalidResponse
        }
        return state
    }

    /// `membershipType` as Cursor writes it — "free", "pro", "business" — made
    /// presentable without inventing a name the vendor did not use.
    private static func planTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 40,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    private static func checkCancellation(_ cancellation: AccountCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
    }
}

protocol CursorHTTPFetching {
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse)
}

/// One ephemeral, proxy-free, redirect-free, cookie-jar-free request to
/// cursor.com and nowhere else.
///
/// Redirects are refused rather than followed, because the request carries a
/// session cookie: a redirect is the one way a borrowed credential could be
/// handed to a host nobody vetted. The response host is checked as well, so a
/// refused redirect cannot be mistaken for an answer.
struct CursorWebHTTP: CursorHTTPFetching {
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "https", request.url?.host == "cursor.com" else {
            throw ManagedAccountError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration, delegate: CursorNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.host == "cursor.com",
              response.expectedContentLength <= 1_048_576 else { throw ManagedAccountError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
            guard data.count < 1_048_576 else { throw ManagedAccountError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class CursorNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
