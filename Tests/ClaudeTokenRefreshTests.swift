import XCTest
import Security
@testable import Codenotch

final class ClaudeTokenRefreshTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var item: ClaudeCredentialSnapshot?
        var error: Error?
        var writes = 0
        var reads = 0
        var onRead: ((Int) throws -> Void)?
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            reads += 1
            try onRead?(reads)
            if let error { throw error }
            return item
        }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            guard expected == item else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let written = ClaudeCredentialSnapshot(reference: expected!.reference, data: data)
            item = written; writes += 1
            return written
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            XCTFail("Remote token rotation must never roll back")
        }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var renewal: ClaudeTokenRenewal {
        .init(accessToken: "fake-new-access", refreshToken: "fake-rotated-refresh", expiresIn: 3600,
              scopes: ["user:profile", "user:inference"], refreshTokenExpiresIn: 86_400)
    }
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func payload(_ keychain: Keychain) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(keychain.item).data) as? [String: Any])
    }
    private func oauth(_ keychain: Keychain) throws -> [String: Any] { try XCTUnwrap(payload(keychain)["claudeAiOauth"] as? [String: Any]) }
    private func update(_ keychain: Keychain, _ change: (inout [String: Any]) -> Void) throws {
        var value = try payload(keychain); change(&value)
        keychain.item = ClaudeCredentialSnapshot(reference: keychain.item!.reference, data: try json(value))
    }
    private func fixture() throws -> (ClaudeCredentialLocation, Keychain) {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ClaudeRefresh-\(UUID())")
        try AccountStorage.privateDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let location = ClaudeCredentialLocation(directory: directory, isDefault: false)
        try AccountStorage.write(json(["oauthAccount": ["accountUuid": "A", "organizationUuid": "O", "emailAddress": "a@example.test"], "theme": "dark"]), to: location.configURL)
        let keychain = Keychain()
        keychain.item = ClaudeCredentialSnapshot(reference: Data([1]), data: try json([
            "claudeAiOauth": ["accessToken": "fake-old-access", "refreshToken": "fake-old-refresh",
                "expiresAt": (now.timeIntervalSince1970 - 1) * 1000, "scopes": ["user:profile", "user:inference"],
                "subscriptionType": "max", "rateLimitTier": "preserved"], "mcpOAuth": ["other": "preserved"]]))
        return (location, keychain)
    }
    private func manager(_ keychain: Keychain, renew: @escaping (String, [String]?) throws -> ClaudeTokenRenewal) -> ClaudeSystemCredentials {
        ClaudeSystemCredentials(keychain: keychain, now: { self.now }, invalidateCache: { _ in }, renew: renew)
    }

    func testExpiredLoginRenewsOnceAndPreservesMetadataAndConfiguration() throws {
        let (location, keychain) = try fixture()
        let originalConfig = try Data(contentsOf: location.configURL)
        var requests = 0
        let credentials = manager(keychain) { token, scopes in
            requests += 1
            XCTAssertEqual(token, "fake-old-refresh")
            XCTAssertEqual(scopes, ["user:profile", "user:inference"])
            return self.renewal
        }
        for _ in 0..<2 {
            let login = try credentials.subscriptionLogin(at: location)
            XCTAssertEqual(login.accessToken, "fake-new-access")
            XCTAssertEqual(login.plan, "max")
        }
        XCTAssertEqual(requests, 1); XCTAssertEqual(keychain.writes, 1)
        XCTAssertEqual(try oauth(keychain)["refreshToken"] as? String, "fake-rotated-refresh")
        XCTAssertEqual(try oauth(keychain)["rateLimitTier"] as? String, "preserved")
        XCTAssertEqual(try payload(keychain)["mcpOAuth"] as? [String: String], ["other": "preserved"])
        XCTAssertEqual(try Data(contentsOf: location.configURL), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.directory.appendingPathComponent(".storage-write.lock").path))
    }

    func testOfficialRefreshWinsWhenRereadUnderLock() throws {
        let (location, keychain) = try fixture()
        keychain.onRead = { count in
            if count == 2 {
                try self.update(keychain) { value in
                    var oauth = value["claudeAiOauth"] as! [String: Any]
                    oauth["accessToken"] = "fake-official-new"
                    oauth["expiresAt"] = (self.now.timeIntervalSince1970 + 3600) * 1000
                    value["claudeAiOauth"] = oauth
                }
            }
        }
        let credentials = manager(keychain) { _, _ in XCTFail("Already renewed by Claude"); return self.renewal }
        XCTAssertEqual(try credentials.subscriptionLogin(at: location).accessToken, "fake-official-new")
        XCTAssertEqual(keychain.writes, 0)
    }

    func testTwoCredentialInstancesSerializeAndUseTheFirstRotation() async throws {
        let (location, keychain) = try fixture()
        let entered = expectation(description: "First exchange started")
        let release = DispatchSemaphore(value: 0)
        let first = manager(keychain) { _, _ in
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw ClaudeSystemCredentialError.refreshUnavailable }
            return self.renewal
        }
        let second = manager(keychain) { _, _ in XCTFail("Second caller must reuse rotated token"); return self.renewal }
        let firstTask = Task.detached { try first.subscriptionLogin(at: location) }
        await fulfillment(of: [entered], timeout: 2)
        let secondTask = Task.detached { try second.subscriptionLogin(at: location) }
        try await Task.sleep(nanoseconds: 100_000_000)
        release.signal()
        let firstLogin = try await firstTask.value
        let secondLogin = try await secondTask.value
        XCTAssertEqual(firstLogin.accessToken, "fake-new-access")
        XCTAssertEqual(secondLogin.accessToken, "fake-new-access")
        XCTAssertEqual(keychain.writes, 1)
    }

    func testDeniedMissingRefreshAndUnsafeLocationNeverRequestRenewal() throws {
        let (location, keychain) = try fixture()
        let credentials = manager(keychain) { _, _ in XCTFail("Must not request renewal"); return self.renewal }
        keychain.error = ClaudeSystemCredentialError.keychain(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: location))
        keychain.error = nil
        try update(keychain) { value in
            var oauth = value["claudeAiOauth"] as! [String: Any]; oauth.removeValue(forKey: "refreshToken"); value["claudeAiOauth"] = oauth
        }
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: location))
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: .init(directory: location.directory.appendingPathComponent("missing"), isDefault: false)))
        XCTAssertEqual(keychain.writes, 0)
    }

    func testRevokedRefreshAndTransientFailureBackOffUntilCredentialsChange() throws {
        for error: Error in [ClaudeSystemCredentialError.expiredLogin, ClaudeSystemCredentialError.refreshUnavailable, UsageProviderError.rateLimited(retryAfter: 120)] {
            let (location, keychain) = try fixture()
            var requests = 0
            let credentials = manager(keychain) { _, _ in requests += 1; throw error }
            for _ in 0..<3 { XCTAssertThrowsError(try credentials.subscriptionLogin(at: location)) }
            XCTAssertEqual(requests, 1)
            try update(keychain) { $0["reconnected"] = true }
            XCTAssertThrowsError(try credentials.subscriptionLogin(at: location))
            XCTAssertEqual(requests, 2)
        }
    }

    func testCancellationAndShutdownAfterResponseStillPersistRotatedToken() throws {
        for shutdown in [false, true] {
            let (location, keychain) = try fixture()
            let cancellation = AccountCancellation()
            var credentials: ClaudeSystemCredentials!
            credentials = manager(keychain) { _, _ in
                if shutdown { credentials.requestStop() } else { cancellation.cancel() }
                return self.renewal
            }
            XCTAssertThrowsError(try credentials.subscriptionLogin(at: location, cancellation: cancellation))
            credentials.waitUntilIdle()
            XCTAssertEqual(try oauth(keychain)["refreshToken"] as? String, "fake-rotated-refresh")
            XCTAssertEqual(keychain.writes, 1)
        }
    }

    func testCancellationBeforeRequestDoesNotReadOrWrite() throws {
        let (location, keychain) = try fixture()
        let credentials = manager(keychain) { _, _ in XCTFail(); return self.renewal }
        let cancellation = AccountCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: location, cancellation: cancellation))
        XCTAssertEqual(keychain.reads, 0); XCTAssertEqual(keychain.writes, 0)
    }

    func testConcurrentUnrelatedSettingsAndCredentialsAreMerged() throws {
        let (location, keychain) = try fixture()
        let credentials = manager(keychain) { _, _ in
            try self.update(keychain) { $0["newMcpCredential"] = "preserved" }
            var config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: location.configURL)) as? [String: Any])
            config["theme"] = "light"
            try AccountStorage.write(self.json(config), to: location.configURL)
            return self.renewal
        }
        _ = try credentials.subscriptionLogin(at: location)
        XCTAssertEqual(try payload(keychain)["newMcpCredential"] as? String, "preserved")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: location.configURL)) as? [String: Any])
        XCTAssertEqual(config["theme"] as? String, "light")
    }

    func testChangedLoginIsNeverOverwrittenByResponseForPreviousAccount() throws {
        let (location, keychain) = try fixture()
        let credentials = manager(keychain) { _, _ in
            try self.update(keychain) { value in
                var oauth = value["claudeAiOauth"] as! [String: Any]; oauth["refreshToken"] = "fake-other-login"; value["claudeAiOauth"] = oauth
            }
            return self.renewal
        }
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: location))
        XCTAssertEqual(try oauth(keychain)["refreshToken"] as? String, "fake-other-login")
        XCTAssertEqual(keychain.writes, 0)
    }

    func testCacheFailureNeverRollsBackRotationAndNextReadIsFresh() throws {
        let (location, keychain) = try fixture()
        let credentials = ClaudeSystemCredentials(keychain: keychain, now: { self.now },
            invalidateCache: { _ in throw ClaudeSystemCredentialError.unsafePath }, renew: { _, _ in self.renewal })
        XCTAssertThrowsError(try credentials.subscriptionLogin(at: location))
        XCTAssertEqual(try credentials.subscriptionLogin(at: location).accessToken, "fake-new-access")
        XCTAssertEqual(keychain.writes, 1)
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: ClaudeTokenRefresh.endpoint, statusCode: status, httpVersion: nil, headerFields: [:])!
    }
    func testParserAcceptsMissingRefreshTokenAndRejectsMalformedOrRevokedResponses() throws {
        let valid = try ClaudeTokenRefresh.parse(data: json(["access_token": "fake-access", "expires_in": 3600]), response: response(200))
        XCTAssertNil(valid.refreshToken); XCTAssertNil(valid.scopes)
        for object: [String: Any] in [[:], ["access_token": "fake", "expires_in": true],
                                     ["access_token": "fake", "expires_in": -1],
                                     ["access_token": "fake", "expires_in": 3600, "refresh_token": ""],
                                     ["access_token": "fake", "expires_in": 3600, "scope": ["wrong-type"]]] {
            XCTAssertThrowsError(try ClaudeTokenRefresh.parse(data: json(object), response: response(200)))
        }
        XCTAssertThrowsError(try ClaudeTokenRefresh.parse(data: json(["error": "invalid_grant"]), response: response(400))) {
            XCTAssertEqual($0.localizedDescription, ClaudeSystemCredentialError.expiredLogin.localizedDescription)
        }
        XCTAssertThrowsError(try ClaudeTokenRefresh.parse(data: Data(repeating: 65, count: 65_537), response: response(200)))
    }

    private final class Transport: URLProtocol {
        static var requests: [URLRequest] = []
        static var status = 200
        static var bytes = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests.append(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: ["Location": "https://must-not-receive-token.example.test/"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
    func testEphemeralExchangeAndRedirectRejectionUseFakeTransportOnly() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Transport.self]
        Transport.requests = []; Transport.status = 200
        Transport.bytes = try json(["access_token": "fake-access", "refresh_token": "fake-new", "expires_in": 3600, "scope": "user:profile"])
        let result = try ClaudeTokenRefresh.exchange("fake-old", ["user:profile"], configuration: configuration)
        XCTAssertEqual(result.accessToken, "fake-access")
        XCTAssertEqual(Transport.requests.count, 1)
        XCTAssertEqual(Transport.requests[0].url, ClaudeTokenRefresh.endpoint)
        XCTAssertEqual(Transport.requests[0].httpMethod, "POST")
        XCTAssertNil(Transport.requests[0].value(forHTTPHeaderField: "Authorization"))
        Transport.requests = []; Transport.status = 302
        XCTAssertThrowsError(try ClaudeTokenRefresh.exchange("fake-old", ["user:profile"], configuration: configuration))
        XCTAssertEqual(Transport.requests.count, 1)
    }
}
