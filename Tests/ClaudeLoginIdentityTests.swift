import XCTest
@testable import Codenotch

/// The token is the truth about who a login is. `.claude.json` names whoever
/// the last Claude session to save it started under, and every running session
/// saves it, so after a switch the Mac's name and its secret disagree within
/// minutes. These tests pin the app to the secret.
final class ClaudeLoginIdentityTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { items[service] }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            guard items[service] == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let written = ClaudeCredentialSnapshot(reference: expected?.reference ?? Data(service.utf8), data: data)
            items[service] = written
            return written
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            guard items[service] == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
            items[service] = previous
        }
        func token(_ service: String) -> String? {
            guard let item = items[service],
                  let object = try? JSONSerialization.jsonObject(with: item.data) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
            return oauth["accessToken"] as? String
        }
    }

    /// Reads usage for whoever the *token* at a location belongs to, the way the
    /// real endpoint does — never for whoever the config claims.
    private final class Runner: AccountCommandRunning, ClaudeAccountReading {
        let keychain: Keychain
        var used: [String: Double] = ["A": 50, "B": 50, "C": 50]
        init(keychain: Keychain) { self.keychain = keychain }
        func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
            guard let token = keychain.token(location.service) else { throw ClaudeSystemCredentialError.missingLogin }
            let owner = String(token.dropFirst("fake-".count))
            return ManagedAccountState(isConnected: true, email: "\(owner)@example.test", plan: "max",
                windows: [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: (used[owner] ?? 50) / 100,
                                      resetsAt: Date().addingTimeInterval(3600))], refreshedAt: Date())
        }
        func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
            XCTFail("No CLI is needed to identify or read a login"); throw ManagedAccountError.unavailable
        }
    }

    private struct Fixture {
        let manager: AccountManager
        let keychain: Keychain
        let credentials: ClaudeSystemCredentials
        let mac: ClaudeCredentialLocation
        let accounts: [String: ManagedAccount]
        let location: (ManagedAccount) -> ClaudeCredentialLocation
    }

    private static func identity(_ id: String) -> ClaudeCredentialIdentity {
        ClaudeCredentialIdentity(accountID: id, organizationID: "org-\(id)", email: "\(id)@example.test")
    }

    @MainActor
    private func fixture(automatic: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("login-identity-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let mac = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(mac.directory)
        let keychain = Keychain()
        let runner = Runner(keychain: keychain)
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "tester", invalidateCache: { _ in })
        let manager = AccountManager(rootURL: root.appendingPathComponent("catalog"), runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/claude") },
            systemCredentials: credentials, systemClaudeDirectory: mac.directory, claudeReader: runner,
            resolveTokenIdentity: { token in
                guard token.hasPrefix("fake-") else { throw ClaudeSystemCredentialError.expiredLogin }
                return Self.identity(String(token.dropFirst("fake-".count)))
            })
        var accounts: [String: ManagedAccount] = [:]
        for name in ["A", "B", "C"] { accounts[name] = try manager.add(provider: .claude, label: name, emailHint: nil) }
        let location: (ManagedAccount) -> ClaudeCredentialLocation = {
            ClaudeCredentialLocation(directory: manager.configurationDirectory(for: $0), isDefault: false)
        }
        for (name, account) in accounts { try Self.seed(location(account), name: name, token: name, keychain: keychain) }
        try Self.seed(mac, name: "A", token: "A", keychain: keychain)
        manager.automaticSelection = automatic
        return Fixture(manager: manager, keychain: keychain, credentials: credentials, mac: mac, accounts: accounts, location: location)
    }

    /// `name` is what the config says; `token` is who the secret really is.
    private static func seed(_ location: ClaudeCredentialLocation, name: String, token: String, keychain: Keychain) throws {
        try AccountStorage.write(JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": name,
            "organizationUuid": "org-\(name)", "emailAddress": "\(name)@example.test", "displayName": "Person \(name)"],
            "projects": ["keep": true]]), to: location.configURL)
        let bytes = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fake-\(token)",
            "refreshToken": "refresh-\(token)", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]])
        keychain.items[location.service] = ClaudeCredentialSnapshot(reference: Data(location.service.utf8), data: bytes)
    }

    private static func name(at location: ClaudeCredentialLocation) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: location.configURL)) as? [String: Any]
        return (object?["oauthAccount"] as? [String: Any])?["accountUuid"] as? String
    }

    // MARK: - The Mac

    @MainActor
    func testTheMacLoginIsWhoeverTheTokenBelongsToNotWhoTheConfigNames() async throws {
        let f = try fixture()
        // A session started as A saved its config after the Mac moved to B.
        try Self.seed(f.mac, name: "A", token: "B", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.manager.systemClaudeAccountID, f.accounts["B"]?.id, "The token says B; the config's A is a session's stale memory")
        XCTAssertEqual(try Self.name(at: f.mac), "B", "The Mac's config is put right so the CLI's own status agrees with what is in use")
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-B", "Naming never touches the secret")
    }

    @MainActor
    func testAConfigOnlyChangeNeverMovesAnything() async throws {
        let f = try fixture()
        await f.manager.refreshAll()
        XCTAssertEqual(f.manager.systemClaudeAccountID, f.accounts["A"]?.id)
        // Only the name flips, the way a session's write-back looks from outside.
        try Self.seed(f.mac, name: "C", token: "A", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.manager.systemClaudeAccountID, f.accounts["A"]?.id, "A renamed config is not a new login")
        XCTAssertEqual(try Self.name(at: f.mac), "A")
        XCTAssertNil(f.manager.attention)
    }

    // MARK: - Saved profiles

    @MainActor
    func testAProfileHoldingAnotherAccountsSecretIsRepairedFromTheMacWhenTheMacHasItsRealLogin() async throws {
        let f = try fixture()
        // This is the shape a switch left behind after a stale config name:
        // A's profile says A but carries B's secret, and the Mac is really A.
        let a = try XCTUnwrap(f.accounts["A"])
        try Self.seed(f.location(a), name: "A", token: "B", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.keychain.token(f.location(a).service), "fake-A", "A's own login came back from the Mac")
        XCTAssertEqual(try Self.name(at: f.location(a)), "A")
        XCTAssertNil(f.manager.attention, "Nothing is left for the person to do")
        XCTAssertEqual(f.manager.state(for: a).requiresSignIn, false)
    }

    @MainActor
    func testAProfileHoldingAStrangersSecretAsksForASignInAndIsNeverNext() async throws {
        let f = try fixture()
        let b = try XCTUnwrap(f.accounts["B"])
        // B's profile says B but the secret belongs to C, and the Mac is A:
        // nobody has B's real login, so only a sign-in can fix it.
        try Self.seed(f.location(b), name: "B", token: "C", keychain: f.keychain)
        await f.manager.refreshAll()
        let state = f.manager.state(for: b)
        XCTAssertTrue(state.requiresSignIn, "B has no login of its own to switch to")
        XCTAssertFalse(state.isConnected)
        XCTAssertTrue(state.message?.contains("C@example.test") == true, "Says whose login it found: \(state.message ?? "-")")
        XCTAssertNotEqual(f.manager.nextUsableAccount(for: .claude)?.id, b.id, "A profile that is not what it says is never proposed")
        XCTAssertEqual(f.manager.attention?.kind, .reconnect)
        XCTAssertEqual(f.manager.attention?.accountID, b.id)
        XCTAssertEqual(f.keychain.token(f.location(b).service), "fake-C", "The stranger's secret is left where it was, never rewritten to be B")
        XCTAssertEqual(try Self.name(at: f.location(b)), "B", "The row keeps its name; it is not silently turned into C")
    }

    @MainActor
    func testARepairedProfileIsReadAgainAndSwitchable() async throws {
        let f = try fixture()
        let b = try XCTUnwrap(f.accounts["B"])
        try Self.seed(f.location(b), name: "B", token: "C", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertTrue(f.manager.state(for: b).requiresSignIn)
        // A fresh sign-in, as the CLI would leave it: new secret, own name.
        try Self.seed(f.location(b), name: "B", token: "B", keychain: f.keychain)
        await f.manager.resolveLoginIdentities(force: true)
        await f.manager.refresh(b)
        XCTAssertFalse(f.manager.state(for: b).requiresSignIn)
        XCTAssertTrue(f.manager.state(for: b).isConnected)
        XCTAssertNil(f.manager.attention)
    }

    // MARK: - A session's write-back after a switch

    @MainActor
    func testTheChoiceIsPutBackWhenASessionWritesTheOldLoginOverIt() async throws {
        let f = try fixture()
        let a = try XCTUnwrap(f.accounts["A"]), b = try XCTUnwrap(f.accounts["B"])
        await f.manager.refreshAll()
        await f.manager.launch(b, project: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(f.manager.systemClaudeAccountID, b.id)
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-B")
        // A session started as A renews its token and writes it back over B —
        // a newer A token than the one saved into A's profile.
        try Self.seed(f.mac, name: "A", token: "A", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.manager.systemClaudeAccountID, b.id, "The person's choice stands")
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-B")
        XCTAssertEqual(f.keychain.token(f.location(a).service), "fake-A", "What the session renewed was saved into A's profile, not lost")
        XCTAssertTrue(f.manager.notice?.contains("restored") == true, "Says what happened: \(f.manager.notice ?? "-")")
        XCTAssertTrue(f.manager.notice?.contains("A") == true)
        XCTAssertNil(f.manager.attention)
    }

    @MainActor
    func testAnOutsideChangeIsAdoptedWhenRotationIsOff() async throws {
        let f = try fixture(automatic: false)
        let b = try XCTUnwrap(f.accounts["B"])
        await f.manager.refreshAll()
        await f.manager.launch(b, project: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(f.manager.systemClaudeAccountID, b.id)
        try Self.seed(f.mac, name: "A", token: "A", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.manager.systemClaudeAccountID, f.accounts["A"]?.id, "With rotation off the app follows, it does not argue")
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-A")
        XCTAssertEqual(f.manager.selectedAccount(for: .claude)?.id, f.accounts["A"]?.id)
    }

    @MainActor
    func testRestoringIsBoundedSoTwoWritersNeverFightAllAfternoon() async throws {
        let f = try fixture()
        let b = try XCTUnwrap(f.accounts["B"])
        await f.manager.refreshAll()
        await f.manager.launch(b, project: URL(fileURLWithPath: "/tmp"))
        for _ in 0..<AccountManager.restorationLimit {
            try Self.seed(f.mac, name: "A", token: "A", keychain: f.keychain)
            await f.manager.refreshAll()
            XCTAssertEqual(f.keychain.token(f.mac.service), "fake-B")
        }
        try Self.seed(f.mac, name: "A", token: "A", keychain: f.keychain)
        await f.manager.refreshAll()
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-A", "Past the limit the change stands")
        XCTAssertEqual(f.manager.systemClaudeAccountID, f.accounts["A"]?.id)
    }

    // MARK: - The switch itself

    @MainActor
    func testASwitchSavesTheOutgoingLoginUnderItsOwnNameEvenWhenTheMacConfigLies() async throws {
        let f = try fixture()
        let a = try XCTUnwrap(f.accounts["A"]), b = try XCTUnwrap(f.accounts["B"])
        await f.manager.refreshAll()
        // The Mac really is A; a session started as C has just saved its config.
        try Self.seed(f.mac, name: "C", token: "A", keychain: f.keychain)
        await f.manager.launch(b, project: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(f.manager.systemClaudeAccountID, b.id, f.manager.notice ?? "")
        XCTAssertEqual(f.keychain.token(f.mac.service), "fake-B")
        XCTAssertEqual(try Self.name(at: f.mac), "B")
        XCTAssertEqual(f.keychain.token(f.location(a).service), "fake-A")
        XCTAssertEqual(try Self.name(at: f.location(a)), "A", "A's profile was never renamed to C")
        XCTAssertEqual(try Self.name(at: f.location(f.accounts["C"]!)), "C")
    }

    // MARK: - The resolver

    private final class Transport: URLProtocol {
        static var requests = 0
        static var status = 200
        static var payload = Data()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requests += 1
            XCTAssertEqual(request.url, ClaudeTokenIdentityResolver.endpoint)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer FAKE-TEST-ONLY")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func resolver() -> ClaudeTokenIdentityResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Transport.self]
        Transport.requests = 0; Transport.status = 200
        Transport.payload = Data(#"{"account":{"uuid":"acc-1","email":"who@example.test"},"organization":{"uuid":"org-1","name":"Org"}}"#.utf8)
        return ClaudeTokenIdentityResolver(session: URLSession(configuration: configuration))
    }

    func testATokenIsAskedAboutOnceAndRemembered() async throws {
        let resolver = resolver()
        let first = try await resolver.identity(forToken: "FAKE-TEST-ONLY")
        XCTAssertEqual(first, ClaudeCredentialIdentity(accountID: "acc-1", organizationID: "org-1", email: "who@example.test"))
        XCTAssertEqual(first.email, "who@example.test")
        _ = try await resolver.identity(forToken: "FAKE-TEST-ONLY")
        XCTAssertEqual(Transport.requests, 1, "A token never changes owner; one question is enough")
    }

    func testARefusedTokenIsNotAskedAboutAgainRightAway() async throws {
        let resolver = resolver()
        Transport.status = 401
        for _ in 0..<2 {
            do { _ = try await resolver.identity(forToken: "FAKE-TEST-ONLY"); XCTFail("A refused token has no owner") }
            catch ClaudeSystemCredentialError.expiredLogin {} catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(Transport.requests, 1)
    }

    func testAnAnswerWithoutAnAccountIsNotAnIdentity() async throws {
        let resolver = resolver()
        Transport.payload = Data(#"{"organization":{"uuid":"org-1"}}"#.utf8)
        do { _ = try await resolver.identity(forToken: "FAKE-TEST-ONLY"); XCTFail() }
        catch ManagedAccountError.invalidResponse {} catch { XCTFail("\(error)") }
    }

    func testAFingerprintNeverContainsTheToken() {
        let print = ClaudeTokenIdentityResolver.fingerprint("sk-ant-oat01-secret-secret")
        XCTAssertEqual(print.count, 16)
        XCTAssertFalse(print.contains("secret"))
    }
}
