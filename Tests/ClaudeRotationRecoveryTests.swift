import XCTest
@testable import Codenotch

/// Runs the real usage reader, renewal transaction and automatic selector together.
/// All credentials and HTTP responses are synthetic; no real account is touched.
final class ClaudeRotationRecoveryTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        var deniedServices: Set<String> = []
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? {
            if deniedServices.contains(service) { throw ClaudeSystemCredentialError.keychain(-25293) }
            return items[service]
        }
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
    private func fixture(revokeTarget: Bool = false, incompleteSystem: Bool = false,
                         failSystemInvalidation: Bool = false) throws -> (AccountManager, Keychain, ClaudeSystemCredentials, ClaudeCredentialLocation, [ManagedAccount]) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("rotation-renewal-\(UUID())")
        try AccountStorage.privateDirectory(root)
        let system = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(system.directory)
        let keychain = Keychain()
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "test-only", invalidateCache: { location in
            if failSystemInvalidation && location.isDefault { throw CocoaError(.fileWriteNoPermission) }
            try ClaudeSystemCredentials.invalidateLoginCache(at: location)
        }, renew: { token, scopes in
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
        if incompleteSystem {
            keychain.items[system.service] = ClaudeCredentialSnapshot(reference: Data(system.service.utf8),
                data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["scopes": ["user:profile"]],
                    "unrelated": ["keep": true]], options: .prettyPrinted))
        }
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

    @MainActor
    func testIncompleteSystemLoginAutomaticallyUsesHealthyAccountWithoutChangingExpiredBackup() async throws {
        let (manager, keychain, credentials, system, accounts) = try fixture(incompleteSystem: true)
        let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
        let savedSecret = keychain.items[saved.service]
        let savedConfig = try Data(contentsOf: saved.configURL)
        manager.automaticSelection = true

        await manager.refreshAll()

        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id)
        XCTAssertEqual(manager.automaticSwitch?.toID, accounts[1].id)
        XCTAssertFalse(manager.notice?.contains("paused") == true)
        XCTAssertEqual(try credentials.subscriptionLogin(at: system).accessToken, "TEST-ONLY-B-renewed")
        XCTAssertEqual(keychain.items[saved.service], savedSecret)
        XCTAssertEqual(try Data(contentsOf: saved.configURL), savedConfig)
        let payload = try JSONSerialization.jsonObject(with: XCTUnwrap(keychain.items[system.service]?.data)) as! [String: Any]
        XCTAssertEqual(payload["unrelated"] as? [String: Bool], ["keep": true])
    }

    @MainActor
    func testExplicitUseRecoversIncompleteOrMissingSystemLoginWithExistingBackup() async throws {
        for missing in [false, true] {
            let (manager, keychain, credentials, system, accounts) = try fixture(incompleteSystem: true)
            if missing { keychain.items[system.service] = nil }
            let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
            let before = keychain.items[saved.service]
            let config = try Data(contentsOf: saved.configURL)

            await manager.launch(accounts[1], project: system.directory)

            XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
            XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id)
            XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
            XCTAssertNil(manager.automaticSwitch)
            XCTAssertEqual(keychain.items[saved.service], before)
            XCTAssertEqual(try Data(contentsOf: saved.configURL), config)
        }
    }

    @MainActor
    func testIncompleteSystemLoginRefusesMissingMalformedOrWrongIdentityBackup() async throws {
        for damage in ["missing", "incomplete", "identity"] {
            let (manager, keychain, credentials, system, accounts) = try fixture(incompleteSystem: true)
            let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
            switch damage {
            case "missing": keychain.items[saved.service] = nil
            case "incomplete":
                keychain.items[saved.service] = ClaudeCredentialSnapshot(reference: Data(saved.service.utf8),
                    data: Data("{\"claudeAiOauth\":{\"accessToken\":\"TEST-ONLY\"}}".utf8))
            default:
                let other = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[1]), isDefault: false)
                try AccountStorage.write(Data(contentsOf: other.configURL), to: saved.configURL)
            }
            let beforeSystem = keychain.items[system.service]
            let beforeSaved = keychain.items[saved.service]
            let beforeConfig = try Data(contentsOf: system.configURL)

            await manager.launch(accounts[1], project: system.directory)

            XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A", damage)
            XCTAssertNotEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id, damage)
            XCTAssertEqual(keychain.items[system.service], beforeSystem, damage)
            XCTAssertEqual(keychain.items[saved.service], beforeSaved, damage)
            XCTAssertEqual(try Data(contentsOf: system.configURL), beforeConfig, damage)
        }
    }

    @MainActor
    func testDeniedSystemKeychainNeverUsesBackupToBypassAccessFailure() async throws {
        let (manager, keychain, credentials, system, accounts) = try fixture()
        let before = keychain.items[system.service]
        let config = try Data(contentsOf: system.configURL)
        keychain.deniedServices.insert(system.service)

        await manager.launch(accounts[1], project: system.directory)

        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertNotEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id)
        XCTAssertEqual(keychain.items[system.service], before)
        XCTAssertEqual(try Data(contentsOf: system.configURL), config)
    }

    @MainActor
    func testFailedRecoveredSwitchRestoresOriginalIncompleteSystemBytes() async throws {
        let (manager, keychain, credentials, system, accounts) = try fixture(incompleteSystem: true, failSystemInvalidation: true)
        let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
        let beforeSaved = keychain.items[saved.service]
        let beforeSystem = keychain.items[system.service]
        let beforeConfig = try Data(contentsOf: system.configURL)
        manager.automaticSelection = true

        await manager.refreshAll()

        XCTAssertEqual(manager.systemClaudeAccountID, accounts[0].id)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertNil(manager.automaticSwitch)
        XCTAssertTrue(manager.notice?.contains("paused") == true)
        XCTAssertEqual(keychain.items[system.service], beforeSystem)
        XCTAssertEqual(keychain.items[saved.service], beforeSaved)
        XCTAssertEqual(try Data(contentsOf: system.configURL), beforeConfig)
    }

    @MainActor
    func testNonJSONSystemCredentialIsNeverOverwrittenDuringRecovery() async throws {
        let (manager, keychain, _, system, accounts) = try fixture(incompleteSystem: true)
        keychain.items[system.service] = ClaudeCredentialSnapshot(reference: Data(system.service.utf8), data: Data("broken-json".utf8))
        let before = keychain.items[system.service]
        let config = try Data(contentsOf: system.configURL)

        await manager.launch(accounts[1], project: system.directory)

        XCTAssertEqual(keychain.items[system.service], before)
        XCTAssertEqual(try Data(contentsOf: system.configURL), config)
        XCTAssertNotEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id)
    }

    @MainActor
    func testPartialSystemTokenIsNeverDiscardedForAnOlderBackup() async throws {
        for tokenKey in ["accessToken", "refreshToken"] {
            let (manager, keychain, _, system, accounts) = try fixture(incompleteSystem: true)
            keychain.items[system.service] = ClaudeCredentialSnapshot(reference: Data(system.service.utf8),
                data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [tokenKey: "TEST-ONLY-newer-fragment"]]))
            let before = keychain.items[system.service]
            let config = try Data(contentsOf: system.configURL)

            await manager.launch(accounts[1], project: system.directory)

            XCTAssertEqual(keychain.items[system.service], before, tokenKey)
            XCTAssertEqual(try Data(contentsOf: system.configURL), config, tokenKey)
            XCTAssertNotEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id, tokenKey)
        }
    }
}
