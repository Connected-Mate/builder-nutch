import Foundation
import CoreFoundation
import Darwin

/// Uses the official CLI's documented, authenticated loopback API. The
/// transient server password belongs to this manager; vendor credentials are
/// never opened, copied or passed to HTTP by the manager.
enum KimiAccountIntegration {
    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // This distribution exposes the KIMI_CODE_HOME/password server contract.
        // A similarly named legacy Python CLI does not share that contract.
        let path = home.appendingPathComponent(".kimi-code/bin/kimi")
        return FileManager.default.isExecutableFile(atPath: path.path) ? path : nil
    }

    static func isolatedEnvironment(profile: URL, inherited: [String: String]) -> [String: String] {
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "COLORTERM", "SSH_AUTH_SOCK"]
        var result = inherited.filter { allowed.contains($0.key) }
        result["PATH"] = result["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        result["KIMI_CODE_HOME"] = profile.path
        result["HOME"] = profile.appendingPathComponent("home", isDirectory: true).path
        return result
    }

    @MainActor
    static func read(executable: URL, profile: URL, environment: [String: String],
                     cancellation: AccountCancellation) async throws -> ManagedAccountState {
        try await read(executable: executable, profile: profile, environment: environment,
                       cancellation: cancellation, runner: OfficialAccountProcess(),
                       http: KimiLoopbackHTTP(), port: availablePort)
    }

    /// Dependencies make lifecycle and HTTP failure tests entirely synthetic.
    @MainActor
    static func read(executable: URL, profile: URL, environment: [String: String],
                     cancellation: AccountCancellation, runner: any AccountCommandRunning,
                     http: any KimiHTTPFetching, port: () throws -> UInt16,
                     startupTimeout: TimeInterval = 8, pollInterval: TimeInterval = 0.15) async throws -> ManagedAccountState {
        try AccountStorage.privateDirectory(profile)
        try AccountStorage.privateDirectory(profile.appendingPathComponent("home", isDirectory: true))
        for attempt in 0..<2 {
            try checkCancellation(cancellation)
            let serverCancellation = AccountCancellation()
            let selectedPort = try port()
            let password = UUID().uuidString + UUID().uuidString
            var isolated = isolatedEnvironment(profile: profile, inherited: environment)
            isolated["KIMI_CODE_PASSWORD"] = password
            // Redirection discards the startup banner before it reaches any
            // collector: it can contain the CLI's persistent bearer token.
            // Every argument is positional, so paths never become shell code.
            let command = AccountCommand(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec \"$@\" >/dev/null 2>&1", "builder-nutch-kimi", executable.path,
                            "web", "--no-open", "--host", "127.0.0.1", "--port", String(selectedPort)],
                environment: isolated, directory: profile, timeout: startupTimeout + 12)
            let processState = KimiProcessState()
            let server = Task { @MainActor in
                do { _ = try await runner.run(command, cancellation: serverCancellation) }
                catch { processState.failed = true }
                processState.finished = true
            }
            let result: Result<ManagedAccountState, Error> = await withTaskCancellationHandler {
                do {
                    let deadline = Date().addingTimeInterval(startupTimeout)
                    var ready = false
                    while Date() < deadline {
                        try checkCancellation(cancellation)
                        if processState.finished { throw KimiReadError.serverUnavailable }
                        do {
                            _ = try await get("meta", port: selectedPort, password: password, http: http, cancellation: cancellation)
                            ready = true
                            break
                        } catch is CancellationError { throw ManagedAccountError.cancelled }
                        catch {
                            try checkCancellation(cancellation)
                            try await Task.sleep(nanoseconds: UInt64(max(0.001, pollInterval) * 1_000_000_000))
                        }
                    }
                    guard ready, !processState.finished else { throw KimiReadError.serverUnavailable }
                    let auth = try await get("auth", port: selectedPort, password: password, http: http, cancellation: cancellation)
                    // Never ask usage for a plain API-key configuration.
                    guard try isSubscriptionAuthenticated(auth) else {
                        return .success(ManagedAccountState(message: "Connect a Kimi Code subscription through the browser."))
                    }
                    let usage = try await get("oauth/usage", port: selectedPort, password: password, http: http, cancellation: cancellation)
                    try checkCancellation(cancellation)
                    guard !processState.finished else { throw KimiReadError.serverUnavailable }
                    return .success(try state(auth: auth, usage: usage))
                } catch { return .failure(error) }
            } onCancel: {
                serverCancellation.cancel()
            }
            // Await the existing runner's owned-process-group cleanup on every
            // path, including cancellation, failed HTTP and early server exit.
            serverCancellation.cancel()
            await server.value
            try checkCancellation(cancellation)
            switch result {
            case .success(let state): return state
            case .failure(let error):
                if error is KimiReadError, attempt == 0 { continue }
                throw error
            }
        }
        throw KimiReadError.serverUnavailable
    }

    private static func checkCancellation(_ cancellation: AccountCancellation) throws {
        if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
    }

    private static func get(_ path: String, port: UInt16, password: String,
                            http: any KimiHTTPFetching, cancellation: AccountCancellation) async throws -> [String: Any] {
        try checkCancellation(cancellation)
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/\(path)") else { throw ManagedAccountError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.fetch(request, cancellation: cancellation)
        try checkCancellation(cancellation)
        guard response.statusCode == 200, response.url?.host == "127.0.0.1",
              response.url?.port == Int(port) else { throw ManagedAccountError.invalidResponse }
        let envelope = try AccountQuotas.json(data)
        guard let code = number(envelope["code"]), code == 0,
              let payload = envelope["data"] as? [String: Any] else { throw ManagedAccountError.invalidResponse }
        return payload
    }

    static func isSubscriptionAuthenticated(_ auth: [String: Any]) throws -> Bool {
        // Installed 0.29 exposes ready; newer releases call it models_ready.
        guard let ready = boolean(auth["models_ready"] ?? auth["ready"]) else { throw ManagedAccountError.invalidResponse }
        guard let managed = auth["managed_provider"] as? [String: Any] else { return false }
        guard let name = managed["name"] as? String, let status = managed["status"] as? String else { throw ManagedAccountError.invalidResponse }
        return ready && name == "managed:kimi-code" && status == "authenticated"
    }

    static func state(auth: [String: Any], usage: [String: Any], now: Date = Date()) throws -> ManagedAccountState {
        guard try isSubscriptionAuthenticated(auth) else {
            return ManagedAccountState(message: "Connect a Kimi Code subscription through the browser.")
        }
        var state = ManagedAccountState(isConnected: true)
        guard let kind = usage["kind"] as? String else { throw ManagedAccountError.invalidResponse }
        if kind == "error" {
            state.message = "Kimi is connected. Subscription usage is temporarily unavailable; refresh to try again."
            return state
        }
        guard kind == "ok", let limits = usage["limits"] as? [Any], limits.count <= 50 else { throw ManagedAccountError.invalidResponse }
        if let summary = usage["summary"] as? [String: Any] {
            state.windows.append(try window(summary, id: "primary", fallback: "Subscription limit"))
        } else if usage["summary"] != nil && !(usage["summary"] is NSNull) { throw ManagedAccountError.invalidResponse }
        for (index, item) in limits.enumerated() {
            guard let row = item as? [String: Any] else { throw ManagedAccountError.invalidResponse }
            let window = try window(row, id: "limit-\(index)", fallback: "Usage limit \(index + 1)")
            // The server can repeat its primary summary among its windows.
            if !state.windows.contains(where: { $0.label == window.label && $0.usedFraction == window.usedFraction && $0.resetsAt == window.resetsAt }) {
                state.windows.append(window)
            }
        }
        if state.windows.isEmpty { state.message = "Kimi is connected. No subscription limits were reported." }
        else { state.refreshedAt = now }
        // The pay-as-you-go wallet is deliberately not added to subscription
        // allowance, nor used to make an exhausted subscription selectable.
        return state
    }

    private static func window(_ row: [String: Any], id: String, fallback: String) throws -> LimitWindow {
        guard let used = number(row["used"]), let limit = number(row["limit"]), used >= 0, limit >= 0 else { throw ManagedAccountError.invalidResponse }
        var label = text(row["label"]) ?? text(row["name"])
        if label == nil, let duration = row["window"] as? [String: Any],
           let amount = number(duration["duration"]), amount > 0, amount.rounded() == amount,
           let unit = duration["unit"] as? String, ["minute", "hour", "day", "week"].contains(unit) {
            label = "\(String(format: "%.0f", amount)) \(unit) limit"
        }
        let reset = AccountQuotas.date(row["reset_at"])
        if let value = row["reset_at"], !(value is NSNull), reset == nil { throw ManagedAccountError.invalidResponse }
        // reset_hint is human text, not a timestamp. It never becomes an
        // invented date, even if it happens to contain a number.
        return LimitWindow(id: id, label: label ?? fallback,
                           usedFraction: limit > 0 ? min(1, used / limit) : (used > 0 ? 1 : nil),
                           resetsAt: reset)
    }

    private static func text(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 120, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KimiReadError.serverUnavailable }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw KimiReadError.serverUnavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard result == 0, address.sin_port != 0 else { throw KimiReadError.serverUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}

private enum KimiReadError: LocalizedError {
    case serverUnavailable
    var errorDescription: String? { "Kimi's private local server did not become available. Update Kimi Code and try again." }
}

@MainActor
private final class KimiProcessState {
    var finished = false
    var failed = false
}

protocol KimiHTTPFetching {
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral, proxy-free, redirect-free requests to the owned loopback server.
/// Streaming bounds response memory and keeps cookies out of the session.
struct KimiLoopbackHTTP: KimiHTTPFetching {
    func fetch(_ request: URLRequest, cancellation: AccountCancellation) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme == "http", request.url?.host == "127.0.0.1" else { throw ManagedAccountError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: KimiNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= 524_288 else { throw ManagedAccountError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            if cancellation.isCancelled || Task.isCancelled { throw ManagedAccountError.cancelled }
            guard data.count < 524_288 else { throw ManagedAccountError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class KimiNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
