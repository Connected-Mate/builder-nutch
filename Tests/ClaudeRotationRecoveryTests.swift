import XCTest
@testable import Codenotch

/// Runs the real usage reader, renewal transaction and automatic selector together.
/// All credentials and HTTP responses are synthetic; no real account is touched.
final class ClaudeRotationRecoveryTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { items[service] }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            guard items[service] == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let result = ClaudeCredentialSnapshot(reference: expected?.reference ?? Data(service.utf8), data: data)
            items[service] = result
            return result
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            guard items[service] == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
            items[service] = previous
        }
    }

    private struct NoProcesses: AccountCommandRunning {
        func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
            XCTFail("Renewal and rotation must not launch a CLI or terminal")
            throw ManagedAccountError.unavailable
        }
    }

    private final class Usage: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
            let token = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertTrue(["Bearer TEST-ONLY-A-renewed", "Bearer TEST-ONLY-B-renewed"].contains(token))
            let used = token == "Bearer TEST-ONLY-A-renewed" ? 99 : 10
            let data = Data("{\"five_hour\":{\"utilization\":\(used)},\"seven_day\":{\"utilization\":10}}".utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    @MainActor
    private func fixture(revokeTarget: Bool = false) throws -> (AccountManager, Keychain, ClaudeSystemCredentials, ClaudeCredentialLocation, [ManagedAccount]) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("rotation-renewal-\(UUID())")
        try AccountStorage.privateDirectory(root)
        let system = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(system.directory)
        let keychain = Keychain()
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "test-only", renew: { token, scopes in
            guard ["TEST-ONLY-refresh-A", "TEST-ONLY-refresh-B"].contains(token) else {
                XCTFail("A rotated refresh token was reused"); throw ClaudeSystemCredentialError.expiredLogin
            }
            if revokeTarget && token == "TEST-ONLY-refresh-B" { throw ClaudeSystemCredentialError.expiredLogin }
            let id = token.hasSuffix("A") ? "A" : "B"
            return ClaudeTokenRenewal(accessToken: "TEST-ONLY-\(id)-renewed", refreshToken: "TEST-ONLY-\(id)-rotated",
                expiresIn: 3600, scopes: scopes, refreshTokenExpiresIn: nil)
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Usage.self]
        let reader = ClaudeQuietUsageReader(credentials: credentials, session: URLSession(configuration: configuration))
        let manager = AccountManager(rootURL: root.appendingPathComponent("catalog"), runner: NoProcesses(),
            executable: { _ in nil }, openTerminal: { _ in XCTFail("Existing terminal must remain open"); return false },
            systemCredentials: credentials, systemClaudeDirectory: system.directory, claudeReader: reader)
        let accounts = try ["A", "B"].map { try manager.add(provider: .claude, label: $0, emailHint: nil) }
        func seed(_ location: ClaudeCredentialLocation, id: String) throws {
            try AccountStorage.write(JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": id,
                "organizationUuid": "org-\(id)", "emailAddress": "\(id)@example.test"]]), to: location.configURL)
            let bytes = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "TEST-ONLY-\(id)-expired",
                "refreshToken": "TEST-ONLY-refresh-\(id)", "expiresAt": Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000,
                "scopes": ["user:profile", "user:inference"]], "unrelated": ["keep": true]])
            keychain.items[location.service] = ClaudeCredentialSnapshot(reference: Data(location.service.utf8), data: bytes)
        }
        for account in accounts {
            try seed(ClaudeCredentialLocation(directory: manager.configurationDirectory(for: account), isDefault: false), id: account.label)
        }
        try seed(system, id: "A")
        addTeardownBlock {
            await manager.shutdownAndWait()
            try? FileManager.default.removeItem(at: root)
        }
        return (manager, keychain, credentials, system, accounts)
    }

    @MainActor
    func testExpiredSubscriptionsRenewBeforeAutomaticSwitchAndSaveOutgoingRotation() async throws {
        let (manager, keychain, credentials, system, accounts) = try fixture()
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertEqual(manager.automaticSwitch?.toID, accounts[1].id)
        XCTAssertEqual(try credentials.subscriptionLogin(at: system).accessToken, "TEST-ONLY-B-renewed")
        let outgoing = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
        XCTAssertEqual(try credentials.subscriptionLogin(at: outgoing).accessToken, "TEST-ONLY-A-renewed")
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(keychain.items[outgoing.service]?.data)) as! [String: Any]
        XCTAssertEqual((object["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "TEST-ONLY-A-rotated")
        XCTAssertEqual(object["unrelated"] as? [String: Bool], ["keep": true])
    }

    @MainActor
    func testRevokedTargetNeverReportsAutomaticSwitchOrReplacesCurrentLogin() async throws {
        let (manager, _, credentials, system, accounts) = try fixture(revokeTarget: true)
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[0].id)
        XCTAssertNil(manager.automaticSwitch)
        XCTAssertFalse(manager.state(for: accounts[1]).isFresh())
        XCTAssertEqual(try credentials.subscriptionLogin(at: system).accessToken, "TEST-ONLY-A-renewed")
    }
}
