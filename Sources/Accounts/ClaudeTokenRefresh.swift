import Foundation
import CoreFoundation

struct ClaudeTokenRenewal {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval
    let scopes: [String]?
    let refreshTokenExpiresIn: TimeInterval?
}

/// A single bounded OAuth exchange. It never follows redirects, uses ambient
/// credentials/cookies, logs response bodies, or starts an external process.
enum ClaudeTokenRefresh {
    static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let maximumBytes = 65_536

    static func scopes(_ value: Any?) throws -> [String]? {
        guard let value else { return nil }
        let values: [String]
        if let array = value as? [String] { values = array }
        else if let text = value as? String { values = text.split(separator: " ").map(String.init) }
        else { throw ClaudeSystemCredentialError.malformedData }
        guard !values.isEmpty, values.count <= 100, values.allSatisfy({ scope in
            !scope.isEmpty && scope.utf8.count <= 256 && scope.utf8.allSatisfy { $0 == 0x21 || (0x23...0x5b).contains($0) || (0x5d...0x7e).contains($0) }
        }) else { throw ClaudeSystemCredentialError.malformedData }
        return values
    }

    static func exchange(_ refreshToken: String, _ scopes: [String]?) throws -> ClaudeTokenRenewal {
        try exchange(refreshToken, scopes, configuration: .ephemeral)
    }

    // Configuration injection is only for local URLProtocol tests.
    static func exchange(_ refreshToken: String, _ scopes: [String]?, configuration: URLSessionConfiguration) throws -> ClaudeTokenRenewal {
        guard !refreshToken.isEmpty, refreshToken.utf8.count <= 16_384 else { throw ClaudeSystemCredentialError.malformedData }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        if let scopes = try self.scopes(scopes) { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let receiver = Receiver()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        // Deliberately finish an in-flight exchange despite caller cancellation:
        // abandoning a successful response can destroy a rotated refresh token.
        guard receiver.finished.wait(timeout: .now() + 22) == .success else {
            throw ClaudeSystemCredentialError.refreshUnavailable
        }
        let (data, response, failed) = receiver.result()
        guard !failed, let response else { throw ClaudeSystemCredentialError.refreshUnavailable }
        return try parse(data: data, response: response)
    }

    static func parse(data: Data, response: HTTPURLResponse) throws -> ClaudeTokenRenewal {
        guard data.count <= maximumBytes else { throw ClaudeSystemCredentialError.malformedData }
        if response.statusCode == 429 {
            let delay = ClaudeOAuthProvider.retryAfter(from: response) ?? 60
            throw UsageProviderError.rateLimited(retryAfter: max(60, delay))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 401 || response.statusCode == 403 ||
            (response.statusCode == 400 && object?["error"] as? String == "invalid_grant") {
            throw ClaudeSystemCredentialError.expiredLogin
        }
        guard response.statusCode == 200 else { throw ClaudeSystemCredentialError.refreshUnavailable }
        func lifetime(_ value: Any?) -> Double? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0,
                  number.doubleValue <= 366 * 24 * 3600 else { return nil }
            return number.doubleValue
        }
        func token(_ value: Any?) -> String? {
            guard let token = value as? String, !token.isEmpty, token.utf8.count <= 16_384,
                  token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { return nil }
            return token
        }
        guard let object, let access = token(object["access_token"]), let expiry = lifetime(object["expires_in"]) else {
            throw ClaudeSystemCredentialError.malformedData
        }
        let refresh = token(object["refresh_token"])
        let refreshExpiry = lifetime(object["refresh_token_expires_in"])
        guard object["refresh_token"] == nil || refresh != nil,
              object["refresh_token_expires_in"] == nil || refreshExpiry != nil,
              object["scope"] == nil || object["scope"] is String else {
            throw ClaudeSystemCredentialError.malformedData
        }
        return ClaudeTokenRenewal(accessToken: access, refreshToken: refresh, expiresIn: expiry,
                                  scopes: try scopes(object["scope"]), refreshTokenExpiresIn: refreshExpiry)
    }

    private final class Receiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let finished = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()
        private var response: HTTPURLResponse?
        private var failed = false

        func result() -> (Data, HTTPURLResponse?, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (data, response, failed)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            lock.lock()
            self.response = response as? HTTPURLResponse
            let accept = response.expectedContentLength <= Int64(ClaudeTokenRefresh.maximumBytes)
            if !accept { failed = true }
            lock.unlock()
            completionHandler(accept ? .allow : .cancel)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
            lock.lock()
            let overflow = data.count + bytes.count > ClaudeTokenRefresh.maximumBytes
            if overflow { failed = true } else { data.append(bytes) }
            lock.unlock()
            if overflow { dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            if error != nil { failed = true }
            lock.unlock()
            finished.signal()
        }
    }
}
