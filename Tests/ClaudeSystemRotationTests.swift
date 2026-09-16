import XCTest
@testable import Codenotch

final class ClaudeSystemRotationTests: XCTestCase {
    private final class Keychain: ClaudeCredentialKeychain {
        var items: [String: ClaudeCredentialSnapshot] = [:]
        var rejectDefaultWrite = false
        var defaultWriteAttempts = 0
        func read(service: String, account: String) throws -> ClaudeCredentialSnapshot? { items[service] }
        func replace(service: String, account: String, expected: ClaudeCredentialSnapshot?, data: Data) throws -> ClaudeCredentialSnapshot {
            if service == ClaudeProfile.defaultKeychainService { defaultWriteAttempts += 1 }
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

    private final class Runner: AccountCommandRunning, ClaudeAccountReading {
        var used: [String: Double] = ["A": 99, "B": 0]
        var failUsage = false
        var extraWindows: [LimitWindow] = []
        var readingDate: Date? = nil
        var providerRestriction: AccountProviderRestriction? = nil
        /// Accounts whose saved credential is gone or unusable, the way a revoked
        /// refresh token or a half-written Keychain item reads.
        var missingLogin: Set<String> = []
        /// Reads run concurrently across accounts; the log must be thread-safe.
        private let lock = NSLock()
        private var recorded: [URL] = []
        var locations: [URL] {
            get { lock.lock(); defer { lock.unlock() }; return recorded }
            set { lock.lock(); recorded = newValue; lock.unlock() }
        }
        private func record(_ url: URL) { lock.lock(); recorded.append(url); lock.unlock() }
        func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
            record(location.directory)
            if failUsage { throw ManagedAccountError.timedOut }
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: location.configURL)) as! [String: Any]
            guard let identity = config["oauthAccount"] as? [String: String] else { throw ClaudeSystemCredentialError.missingLogin }
            if missingLogin.contains(identity["accountUuid"]!) { throw ClaudeSystemCredentialError.missingLogin }
            return ManagedAccountState(isConnected: true, email: identity["emailAddress"], plan: "max",
                windows: [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: used[identity["accountUuid"]!]! / 100)] + extraWindows,
                refreshedAt: readingDate ?? Date(), providerRestriction: providerRestriction)
        }
        func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
            record(command.directory)
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
    private func fixture(openSucceeds: Bool = true) throws -> (AccountManager, Runner, Keychain, ClaudeSystemCredentials, ClaudeCredentialLocation, [ManagedAccount], () -> Int) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("claude-rotation-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let location = ClaudeCredentialLocation(directory: root.appendingPathComponent(".claude"), isDefault: true)
        try AccountStorage.privateDirectory(location.directory)
        let keychain = Keychain(), runner = Runner()
        let credentials = ClaudeSystemCredentials(keychain: keychain, account: "tester")
        var opened = 0
        let manager = AccountManager(rootURL: root.appendingPathComponent("catalog"), runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/claude") }, openTerminal: { _ in opened += 1; return openSucceeds },
            systemCredentials: credentials, systemClaudeDirectory: location.directory, claudeReader: runner)
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
    func testSonnetSelectionDoesNotTreatFableAsAWholeAccountBlock() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.used["A"] = 50
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        try manager.setClaudeModel("sonnet")
        await manager.refreshAll()
        manager.automaticSelection = true
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertTrue(manager.automaticSelection)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.nextUsableAccount(for: .claude)?.id, accounts[0].id)
        XCTAssertNil(manager.snapshot(for: accounts[1]).block)
        XCTAssertEqual(manager.state(for: accounts[1]).windows.count, 2, "Detail evidence retained")
    }

    @MainActor
    func testHealthySonnetDoesNotRotateBecauseFableIsSpent() async throws {
        let (manager, runner, _, credentials, system, _, _) = try fixture()
        runner.used["A"] = 20
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        try manager.setClaudeModel("sonnet")
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
    }

    @MainActor
    func testChosenModelAndGeneralExhaustionRemainBlocking() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.used["A"] = 50
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        try manager.setClaudeModel("fable")
        await manager.refreshAll()
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertNil(manager.nextUsableAccount(for: .claude))
        try manager.setClaudeModel("sonnet")
        runner.used["B"] = 100
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
    }

    @MainActor
    func testNewSessionChoosesVerifiedFallbackAndKeepsPreference() async throws {
        let (manager, runner, _, _, system, _, opened) = try fixture()
        runner.used = ["A": 20, "B": 0]
        runner.extraWindows = [
            LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable"),
            LimitWindow(id: "seven_day_sonnet", label: "Sonnet", usedFraction: 0.2, modelName: "Sonnet")]
        try manager.setClaudeModel("fable")
        await manager.refreshAll()
        await manager.launchClaudeSession(project: system.directory)
        XCTAssertEqual(opened(), 1)
        XCTAssertEqual(manager.claudeModel, "fable")
        XCTAssertEqual(manager.rotationClaudeModel, "sonnet")
        XCTAssertTrue(manager.notice?.contains("sonnet") == true)
        XCTAssertFalse(manager.isLaunchingClaude)
        let launchers = system.directory.deletingLastPathComponent().appendingPathComponent("catalog/launchers")
        let scripts = try FileManager.default.contentsOfDirectory(at: launchers, includingPropertiesForKeys: nil)
        let script = try String(contentsOf: XCTUnwrap(scripts.first), encoding: .utf8)
        XCTAssertTrue(script.contains("--model 'sonnet'"))
        XCTAssertFalse(script.contains("--fallback-model"), "No unobserved second model controller")
    }

    @MainActor
    func testFollowingClaudeKeepsLaunchedFallbackAcrossAppRestart() async throws {
        let (manager, runner, _, credentials, system, _, opened) = try fixture()
        let settings = system.directory.appendingPathComponent("settings.json")
        try AccountStorage.write(Data("{\"model\":\"fable\"}".utf8), to: settings)
        runner.used = ["A": 20, "B": 0]
        runner.extraWindows = [
            LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable"),
            LimitWindow(id: "seven_day_sonnet", label: "Sonnet", usedFraction: 0.2, modelName: "Sonnet")]
        await manager.refreshAll()
        await manager.launchClaudeSession(project: system.directory)
        XCTAssertEqual(opened(), 1)
        XCTAssertNil(manager.claudeModel)
        XCTAssertEqual(manager.rotationClaudeModel, "sonnet")
        let restarted = AccountManager(rootURL: system.directory.deletingLastPathComponent().appendingPathComponent("catalog"),
            runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/claude") },
            systemCredentials: credentials, systemClaudeDirectory: system.directory, claudeReader: runner)
        XCTAssertEqual(restarted.rotationClaudeModel, "sonnet")
        XCTAssertNil(restarted.claudeModel)
        XCTAssertEqual(restarted.observedClaudeModel, "fable")
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{\"model\":\"fable\"}")
        try AccountStorage.write(Data("{".utf8), to: settings)
        await restarted.refreshAll()
        XCTAssertEqual(restarted.rotationClaudeModel, "sonnet", "Unreadable settings are not a model choice")
        try AccountStorage.write(Data("{\"model\":\"fable\"}".utf8), to: settings)
        await restarted.refreshAll()
        XCTAssertEqual(restarted.rotationClaudeModel, "sonnet", "An unchanged restored setting must retain fallback")
        restarted.shutdown()
    }

    @MainActor
    func testLaterClaudeModelChangeWinsOverEarlierAppChoice() async throws {
        let (manager, _, _, _, system, _, _) = try fixture()
        try manager.setClaudeModel("fable")
        let settings = system.directory.appendingPathComponent("settings.json")
        try AccountStorage.write(Data("{\"model\":\"sonnet\"}".utf8), to: settings)
        await manager.refreshAll()
        XCTAssertEqual(manager.rotationClaudeModel, "sonnet")
        XCTAssertNil(manager.claudeModel)
    }

    @MainActor
    func testFailedTerminalOpenDoesNotClaimFallbackModel() async throws {
        let (manager, runner, _, _, system, _, _) = try fixture(openSucceeds: false)
        runner.used = ["A": 20, "B": 0]
        runner.extraWindows = [
            LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable"),
            LimitWindow(id: "seven_day_sonnet", label: "Sonnet", usedFraction: 0.2, modelName: "Sonnet")]
        try manager.setClaudeModel("fable")
        await manager.refreshAll()
        await manager.launchClaudeSession(project: system.directory)
        XCTAssertNil(manager.claudeSessionModel)
        XCTAssertEqual(manager.rotationClaudeModel, "fable")
        XCTAssertFalse(manager.isLaunchingClaude)
        let catalog = try AccountStorage(root: system.directory.deletingLastPathComponent().appendingPathComponent("catalog")).load()
        XCTAssertNil(catalog.claudeSessionModel)
    }

    @MainActor
    func testNewSessionRefusesUnverifiedModelFallback() async throws {
        let (manager, runner, _, credentials, system, _, opened) = try fixture()
        runner.used["A"] = 50
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        try manager.setClaudeModel("fable")
        await manager.refreshAll()
        await manager.launchClaudeSession(project: system.directory)
        XCTAssertEqual(opened(), 0)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(manager.rotationClaudeModel, "fable")
        XCTAssertFalse(manager.isLaunchingClaude)
    }

    @MainActor
    func testAlternativeModelUsePausesRotationAndSurvivesNextRefresh() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.used["A"] = 50
        await manager.refreshAll()
        manager.automaticSelection = true
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertFalse(manager.automaticSelection)
        XCTAssertTrue(manager.notice?.contains("/model") == true)
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
    }

    @MainActor
    func testFailedAlternativeModelCopyKeepsAutomaticRotationEnabled() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.used["A"] = 50
        await manager.refreshAll()
        manager.automaticSelection = true
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        keychain.rejectDefaultWrite = true
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertTrue(manager.automaticSelection)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
    }

    @MainActor
    func testAlternativeModelUseOnCurrentAccountPausesWithoutClaimingSwitch() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.used["A"] = 50
        await manager.refreshAll()
        manager.automaticSelection = true
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        await manager.launch(accounts[0], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertFalse(manager.automaticSelection)
        XCTAssertTrue(manager.notice?.contains("/model") == true)
        XCTAssertFalse(manager.notice?.contains("Claude now uses") == true)
        await manager.refreshAll()
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertNotEqual(manager.resolvedAttention?.kind, .switched)
    }

    @MainActor
    func testExplicitProviderReportedModelLimitRefusesDefaultWithoutSpentModelWindow() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.providerRestriction = AccountProviderRestriction(label: "Fable unavailable", modelName: "Fable", observedAt: Date())
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
        XCTAssertTrue(manager.notice?.contains("Fable") == true)
    }

    @MainActor
    func testExplicitProviderReportedModelLimitAllowsAlternativeWithSharedHeadroom() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.providerRestriction = AccountProviderRestriction(label: "Fable unavailable", modelName: "Fable", observedAt: Date())
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
    }

    @MainActor
    func testAlternativeModelOverrideRefusesProviderWideRestriction() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.providerRestriction = AccountProviderRestriction(label: "Account restricted", observedAt: Date())
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
        XCTAssertTrue(manager.notice?.contains("Account restricted") == true)
    }

    @MainActor
    func testExplicitSwitchRefusesModelLimitEvenWithUnusedShortAllowance() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
        XCTAssertTrue(manager.notice?.contains("Fable") == true)
    }

    @MainActor
    func testExplicitOtherModelOverrideSwitchesWithFreshSharedAllowance() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.extraWindows = [LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
    }

    @MainActor
    func testOtherModelOverrideNeverBypassesSpentSharedAllowance() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.extraWindows = [LimitWindow(id: "seven_day", label: "Weekly", usedFraction: 1),
                               LimitWindow(id: "seven_day_fable", label: "Fable", usedFraction: 1, modelName: "Fable")]
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
        XCTAssertTrue(manager.notice?.contains("Weekly") == true)
    }

    @MainActor
    func testFailedExplicitRefreshNeverUsesCachedUnusedAllowance() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        await manager.refresh(accounts[1])
        XCTAssertEqual(manager.state(for: accounts[1]).primaryRemainingPercent, 100)
        runner.failUsage = true
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory, allowModelLimitedClaude: true)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
        XCTAssertNotNil(manager.state(for: accounts[1]).usageCheckFailedAt)
    }

    @MainActor
    func testStaleExplicitRefreshCannotReplaceTheMacLogin() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.readingDate = Date().addingTimeInterval(-301)
        let original = keychain.items[system.service]
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "A")
        XCTAssertEqual(keychain.items[system.service], original)
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
        XCTAssertTrue(manager.notice?.contains("paused") == true)
        let attempts = keychain.defaultWriteAttempts
        await manager.refreshAll()
        await manager.refreshAll()
        XCTAssertEqual(keychain.defaultWriteAttempts, attempts, "An automatic write failure must not repeat")
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

    @MainActor
    func testAnIdentityWithNoUsableCredentialAsksForANewSignIn() async throws {
        let (manager, runner, keychain, _, _, accounts, _) = try fixture()
        // Signed in once, so the profile still carries its identity. The saved
        // credential is now incomplete: no refresh token, and expired. Exactly
        // the shape that sat silent until a rotation needed the account.
        let saved = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[1]), isDefault: false)
        keychain.items[saved.service] = ClaudeCredentialSnapshot(reference: Data(saved.service.utf8),
            data: try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fake-B",
                "expiresAt": Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000]]))
        runner.missingLogin.insert("B")
        runner.used["A"] = 40
        manager.automaticSelection = true
        await manager.refreshAll()

        XCTAssertTrue(manager.state(for: accounts[1]).requiresSignIn, "An identity with no usable credential is a lost sign-in")
        let attention = try XCTUnwrap(manager.attention, "A revoked queued account must not sit silent")
        XCTAssertEqual(attention.kind, .reconnect)
        XCTAssertEqual(attention.accountID, accounts[1].id)
        XCTAssertEqual(attention.actionTitle, NSLocalizedString("Reconnect", comment: ""))
    }

    @MainActor
    func testAProfileThatWasNeverSignedInIsNotAFault() async throws {
        let (manager, runner, _, _, _, accounts, _) = try fixture()
        // No identity in the profile at all: this account was added and left.
        let empty = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[1]), isDefault: false)
        try AccountStorage.write(JSONSerialization.data(withJSONObject: ["projects": ["keep": true]]), to: empty.configURL)
        runner.used["A"] = 40
        manager.automaticSelection = true
        await manager.refreshAll()

        XCTAssertFalse(manager.state(for: accounts[1]).requiresSignIn, "Never set up is a task, not a fault")
        // It is still the next account in the queue and still cannot take a
        // session, so the queue rule reports it and should. What it must not be
        // is counted as a sign-in that was lost, which is the rule that used to
        // keep a dormant account red forever.
        XCTAssertEqual(manager.attention?.accountID, accounts[1].id)
    }

    @MainActor
    func testALoginChangedOutsideTheAppIsAdoptedRatherThanIgnored() async throws {
        let (manager, runner, keychain, credentials, system, accounts, _) = try fixture()
        runner.used = ["A": 40, "B": 40]
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[0].id)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, accounts[0].id)

        // Someone runs `claude /login` and signs the Mac into B behind our back.
        let source = ClaudeCredentialLocation(directory: manager.configurationDirectory(for: accounts[1]), isDefault: false)
        try AccountStorage.write(Data(contentsOf: source.configURL), to: system.configURL)
        keychain.items[system.service] = ClaudeCredentialSnapshot(reference: Data(system.service.utf8),
            data: try XCTUnwrap(keychain.items[source.service]?.data))
        await manager.refreshAll()

        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, accounts[1].id,
                       "The catalog must never point at an account the Mac stopped using")
        XCTAssertEqual(manager.health.currentName, "B")
        let resolved = try XCTUnwrap(manager.resolvedAttention)
        XCTAssertEqual(resolved.accountID, accounts[1].id)
        XCTAssertTrue(resolved.title.contains("B"), "kind=\(resolved.kind) title=\(resolved.title)")
    }

    @MainActor
    func testAnInAppSwitchAlwaysLeavesTheCatalogAgreeingWithTheMac() async throws {
        let (manager, _, _, _, _, accounts, _) = try fixture()
        manager.automaticSelection = true
        await manager.refreshAll()
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, manager.systemClaudeAccountID)
        await manager.launch(accounts[0], project: FileManager.default.temporaryDirectory)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, manager.systemClaudeAccountID)
    }

    @MainActor
    func testUsingAnotherAccountClearsTheRedAndConfirmsTheSwitch() async throws {
        let (manager, runner, _, credentials, system, accounts, _) = try fixture()
        runner.used = ["A": 50, "B": 100]
        manager.automaticSelection = true
        await manager.refreshAll()
        // B is spent, so there is nothing to move to: the banner is red.
        XCTAssertEqual(manager.attention?.kind, .queueEmpty)

        // The person switches the Mac to B themselves, the way "Use account" does.
        runner.used["B"] = 10
        await manager.launch(accounts[1], project: system.directory)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertNil(manager.attention, "A red banner must not outlive the problem it described")
        let resolved = try XCTUnwrap(manager.resolvedAttention)
        XCTAssertEqual(resolved.kind, .switched)
        XCTAssertEqual(resolved.accountID, accounts[1].id)
        XCTAssertTrue(resolved.title.contains("B"))
    }

    @MainActor
    func testTheAutomaticSwitchSaysWhyItHappened() async throws {
        let (manager, _, _, _, _, accounts, _) = try fixture()
        manager.automaticSelection = true
        await manager.refreshAll()
        let event = try XCTUnwrap(manager.automaticSwitch)
        XCTAssertEqual(event.toID, accounts[1].id)
        XCTAssertTrue(event.reason.contains("A"), "The reason names the account that ran out")
        XCTAssertTrue(event.reason.contains("5h limit"), "and the window that ran out: \(event.reason)")
        XCTAssertTrue(manager.notice?.contains(event.reason) == true, "The notice leads with the reason")
    }

    @MainActor
    func testPausedSwitchIsReportedAndTheRetryActionClearsIt() async throws {
        let (manager, _, keychain, credentials, system, accounts, _) = try fixture()
        keychain.rejectDefaultWrite = true
        manager.automaticSelection = true
        await manager.refreshAll()
        let paused = try XCTUnwrap(manager.attention, "A pause the person cannot see is the failure being fixed")
        XCTAssertEqual(paused.kind, .switchPaused)
        XCTAssertEqual(paused.actionTitle, NSLocalizedString("Retry", comment: ""))
        XCTAssertTrue(manager.isSystemSwitchPaused)
        XCTAssertFalse(manager.health.isSwitchReady)

        keychain.rejectDefaultWrite = false
        let repaired = await manager.repairAttention()
        XCTAssertTrue(repaired)
        XCTAssertEqual(try credentials.identity(at: system)?.accountID, "B")
        XCTAssertEqual(manager.systemClaudeAccountID, accounts[1].id)
        XCTAssertFalse(manager.isSystemSwitchPaused)
        XCTAssertNil(manager.attention)
        XCTAssertTrue(manager.health.isSwitchReady == false || manager.health.currentName == "B")
    }

    @MainActor
    func testAnEmptyQueueIsAnnouncedBeforeTheCurrentAccountRunsOut() async throws {
        let (manager, runner, _, _, _, accounts, _) = try fixture()
        runner.used = ["A": 50, "B": 100]
        manager.automaticSelection = true
        await manager.refreshAll()
        let empty = try XCTUnwrap(manager.attention)
        XCTAssertEqual(empty.kind, .queueEmpty)
        XCTAssertEqual(empty.accountID, accounts[0].id)
        XCTAssertEqual(empty.actionTitle, NSLocalizedString("Add account", comment: ""))
        XCTAssertFalse(manager.health.isSwitchReady)
        // Naming the account and the limit that stopped it beats a blanket
        // "nothing left", which the person cannot act on.
        XCTAssertEqual(manager.health.reason, "B is next in your order, but its 5h limit is used up.")
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
