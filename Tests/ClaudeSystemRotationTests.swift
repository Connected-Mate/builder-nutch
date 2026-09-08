import XCTest
@testable import Codenotch

final class ClaudeSystemRotationTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        var rejectDefaultWrite = false
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { items[service] }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            if rejectDefaultWrite && service == ClaudeProfile.defaultKeychainService { throw ClaudeSystemCredentialError.keychain(-1) }
            guard items[service] == expected else { throw ClaudeSystemCredentialError.changedDuringCopy }
            let written = ClaudeCredentialSnapshot(reference: expected?.reference ?? Data(service.utf8), data: data)
            items[service] = written
            return written
        }
        func restore(service: String, account: String, written: ClaudeCredentialSnapshot, previous: ClaudeCredentialSnapshot?) throws {
            guard items[service] == written else { throw ClaudeSystemCredentialError.changedDuringCopy }
            items[service] = previous
        }
    }

    private final class Runner: AccountCommandRunning {
        var used: [String: Double] = ["A": 99, "B": 0]
        var failUsage = false
        var locations: [URL] = []
        func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
            locations.append(command.directory)
            let location = ClaudeCredentialLocation(directory: command.directory, isDefault: command.environment["CLAUDE_CONFIG_DIR"] == nil)
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: location.configURL)) as! [String: Any]
            let identity = config["oauthAccount"] as! [String: String]
            if command.readsClaudeUsage {
                if failUsage { throw ManagedAccountError.timedOut }
                return try JSONSerialization.data(withJSONObject: ["subscription_type": "max", "rate_limits_available": true,
                    "rate_limits": ["five_hour": ["utilization": used[identity["accountUuid"]!]!,
                        "resets_at": Date().addingTimeInterval(3600).timeIntervalSince1970]]])
            }
            return try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai", "email": identity["emailAddress"]!, "subscriptionType": "max"])
        }
    }

    @MainActor
    private func fixture() throws -> (AccountManager, Runner, Keychain, ClaudeSystemCredentials, ClaudeCredentialLocation, [ManagedAccount], () -> Int) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("claude-rotation-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let location = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(location.directory)
        let keychain = Keychain(), runner = Runner()
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "tester")
        var opened = 0
        let manager = AccountManager(rootURL: root.appendingPathComponent("catalog"), runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/claude") }, openTerminal: { _ in opened += 1; return true },
            systemCredentials: credentials, systemClaudeDirectory: location.directory)
        let accounts = try ["A", "B"].map { try manager.add(provider: .claude, label: $0, emailHint: "same-hint@example.test") }
        func seed(_ location: ClaudeCredentialLocation, id: String) throws {
            try AccountStorage.write(JSONSerialization.data(withJSONObject: ["oauthAccount": ["accountUuid": id,
                "organizationUuid": "org-\(id)", "emailAddress": "\(id)@example.test"], "projects": ["keep": true]]), to: location.configURL)
            let bytes = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fake-\(id)",
                "refreshToken": "refresh-\(id)", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000]])
            keychain.items[location.service] = ClaudeCredentialSnapshot(reference: Data(location.service.utf8), data: bytes)
        }
        for account in accounts { try seed(ClaudeCredentialLocation(directory: manager.configurationDirectory(for: account), isDefault: false), id: account.label) }
        try seed(location, id: "A")
        return (manager, runner, keychain, credentials, location, accounts, { opened })
    }

    @MainActor
    func testExhaustedSystemLoginRotatesAndPreservesOriginalWithoutOpeningWindow() async throws {
        let (manager, runner, keychain, credentials, system, accounts, opened) = try fixture()
        let original = keychain.items[system.service]?.data
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertEqual(manager.automaticSwitch?.fromID, accounts[0].id)
        XCTAssertEqual(manager.automaticSwitch?.toID, accounts[1].id)
        XCTAssertTrue(runner.locations.contains { $0.standardizedFileURL == system.directory.standardizedFileURL }, "Current account must refresh its live system credential, not an obsolete clone")
        let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[0]), isDefault: false)
        let savedObject = try JSONSerialization.jsonObject(with: XCTUnwrap(keychain.items[saved.service]?.data)) as! NSDictionary
        let oldObject = try JSONSerialization.jsonObject(with: XCTUnwrap(original)) as! NSDictionary
        XCTAssertEqual(savedObject, oldObject)
        XCTAssertEqual(opened(), 0)
    }

    @MainActor
    func testHealthySystemAccountStaysCurrentWhileManualNextIsQueued() async throws {
        let (manager, runner, _, credentials, system, accounts, opened) = try fixture()
        runner.used["A"] = 40
        try manager.setNext(accounts[1])
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[0].id)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id)
        XCTAssertNil(manager.automaticSwitch)
        XCTAssertEqual(opened(), 0)
    }

    @MainActor
    func testFailedUsageCannotSwitchSystemLogin() async throws {
        let (manager, runner, _, credentials, system, _, _) = try fixture()
        runner.failUsage = true
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertNil(manager.automaticSwitch)
    }

    @MainActor
    func testFailedSystemWriteDoesNotAnnounceSuccessfulSwitch() async throws {
        let (manager, _, keychain, credentials, system, accounts, opened) = try fixture()
        keychain.rejectDefaultWrite = true
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[0].id)
        XCTAssertNil(manager.automaticSwitch)
        XCTAssertTrue(manager.notice?.contains("switch failed") == true)
        XCTAssertEqual(opened(), 0)
    }

    @MainActor
    func testExplicitUseChangesSystemAccountEvenWhenAutomaticRotationIsOff() async throws {
        let (manager, _, _, credentials, system, accounts, opened) = try fixture()
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertNil(manager.automaticSwitch)
        XCTAssertEqual(opened(), 0)
    }

    func testExhaustedMiddleAccountContinuesAfterItsOriginalPosition() {
        let now = Date()
        let accounts = (0..<3).map { ManagedAccount(id: UUID(), provider: .claude, label: "\($0)", createdAt: now) }
        let states = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { index, account in
            (account.id, ManagedAccountState(isConnected: true, windows: [LimitWindow(id: "5h", label: "5h", usedFraction: index == 1 ? 1 : 0)], refreshedAt: now))
        })
        XCTAssertEqual(AccountSelection.systemClaude(accounts: accounts, states: states, order: accounts.map(\.id),
            currentID: accounts[1].id, preferredID: accounts[1].id, thresholdPercent: 15)?.id, accounts[2].id)
    }
}
