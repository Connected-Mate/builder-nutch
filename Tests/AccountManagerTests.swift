import XCTest
@testable import Codenotch

final class AccountManagerTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("account-tests-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @MainActor
    func testTwelveAccountsPersistAndSelectionDoesNotTouchDefault() throws {
        let root = try temporary()
        let manager = AccountManager(rootURL: root)
        for provider in [AccountProvider.claude, .codex] {
            for index in 1...6 { try manager.add(provider: provider, label: "\(provider.title) \(index)", emailHint: nil) }
        }
        let last = try XCTUnwrap(manager.accounts.last)
        try manager.select(last)
        try manager.rename(last, to: "Work's account")
        manager.automaticSelection = true
        let restored = AccountManager(rootURL: root)
        XCTAssertEqual(restored.accounts.count, 12)
        XCTAssertEqual(restored.selectedAccount(for: .codex)?.id, last.id)
        XCTAssertEqual(restored.accounts.last?.label, "Work's account")
        XCTAssertTrue(restored.automaticSelection)
        let profile = restored.configurationDirectory(for: last)
        XCTAssertTrue(profile.path.hasSuffix(last.id.uuidString.lowercased()))
        try restored.remove(last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertEqual(restored.accounts.count, 11)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("accounts.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testCorruptCatalogIsPreservedAndBlocksWrites() throws {
        let root = try temporary(), file = root.appendingPathComponent("accounts.json")
        let original = Data("not valid json".utf8); try original.write(to: file)
        let manager = AccountManager(rootURL: root)
        XCTAssertNotNil(manager.notice)
        XCTAssertThrowsError(try manager.add(provider: .codex, label: "New", emailHint: nil))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testRejectsSymlinkRootAndCatalog() throws {
        let root = try temporary(), target = try temporary()
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AccountStorage(root: link))
        let storage = try AccountStorage(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("accounts.json"), withDestinationURL: target.appendingPathComponent("private.json"))
        XCTAssertThrowsError(try storage.load())
    }

    func testEnvironmentAllowlistAndShellEscaping() {
        let profile = URL(fileURLWithPath: "/tmp/private account")
        let env = AccountEnvironment.isolated(profile: profile, provider: .claude, inherited: [
            "HOME": "/Users/test", "PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret",
            "OPENAI_API_KEY": "secret", "CODEX_HOME": "/another/account", "CLAUDE_CODE_USE_BEDROCK": "1", "AWS_PROFILE": "production", "BASH_ENV": "/tmp/inject"
        ])
        XCTAssertEqual(Set(env.keys), ["HOME", "PATH", "CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(AccountEnvironment.quote("it's $(touch /tmp/bad)"), "'it'\\''s $(touch /tmp/bad)'")
        let account = ManagedAccount(id: UUID(), provider: .codex, label: "$(bad)", createdAt: Date())
        let script = AccountEnvironment.launchScript(executable: URL(fileURLWithPath: "/tmp/vendor cli"), account: account,
                                                      profile: profile, project: URL(fileURLWithPath: "/tmp/project's dir"), inherited: ["PATH": "/usr/bin"])
        XCTAssertTrue(script.contains("/usr/bin/env -i"))
        XCTAssertTrue(script.contains("'cli_auth_credentials_store=\"keyring\"'"))
        XCTAssertTrue(script.contains("cd '/tmp/project'\\''s dir'"))
        XCTAssertFalse(script.contains("$(bad)"))
    }

    func testAutomaticSelectionExcludesUnknownStaleWeeklyExhaustedAndOtherVendor() {
        let now = Date()
        let accounts = (0..<7).map { index in ManagedAccount(id: UUID(), provider: index == 6 ? .claude : .codex, label: "\(index)", createdAt: now.addingTimeInterval(Double(index))) }
        func state(_ used: Double, age: TimeInterval = 0) -> ManagedAccountState {
            ManagedAccountState(isConnected: true, windows: [LimitWindow(id: "primary", label: "5h", usedFraction: used, resetsAt: now.addingTimeInterval(2000))], refreshedAt: now.addingTimeInterval(-age))
        }
        var states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, state(0.3)) })
        states[accounts[0].id] = ManagedAccountState(isConnected: true)
        states[accounts[1].id] = state(0.01, age: 301)
        states[accounts[2].id]?.windows.append(LimitWindow(id: "weekly", label: "Week", usedFraction: 1))
        states[accounts[3].id] = state(0.1)
        states[accounts[4].id] = state(0.1)
        states[accounts[5].id]?.message = "Refresh failed"
        states[accounts[6].id] = state(0)
        XCTAssertEqual(AccountSelection.best(provider: .codex, accounts: accounts, states: states, now: now)?.id, accounts[3].id)
        states[accounts[3].id]?.isBusy = true
        XCTAssertEqual(AccountSelection.best(provider: .codex, accounts: accounts, states: states, now: now)?.id, accounts[4].id)
        states[accounts[4].id]?.windows = [LimitWindow(id: "unknown", label: "Unknown")]
        XCTAssertNil(AccountSelection.best(provider: .codex, accounts: accounts, states: states, now: now))
    }

    func testRotationKeepsHealthyCurrentThenAdvancesAndWrapsInOrder() throws {
        let now = Date()
        let accounts = (0..<3).map { index in
            ManagedAccount(id: UUID(), provider: .codex, label: "Account \(index + 1)",
                           createdAt: now.addingTimeInterval(Double(index)))
        }
        func state(remaining: Double) -> ManagedAccountState {
            ManagedAccountState(isConnected: true,
                windows: [LimitWindow(id: "primary", label: "5h", usedFraction: 1 - remaining / 100,
                                     resetsAt: now.addingTimeInterval(3600))], refreshedAt: now)
        }
        var states = [accounts[0].id: state(remaining: 40), accounts[1].id: state(remaining: 80), accounts[2].id: state(remaining: 60)]
        let order = accounts.map(\.id)
        XCTAssertEqual(AccountSelection.rotating(provider: .codex, accounts: accounts, states: states,
            order: order, currentID: accounts[0].id, thresholdPercent: 15, now: now)?.id, accounts[0].id)
        states[accounts[0].id] = state(remaining: 15)
        XCTAssertEqual(AccountSelection.rotating(provider: .codex, accounts: accounts, states: states,
            order: order, currentID: accounts[0].id, thresholdPercent: 15, now: now)?.id, accounts[1].id)
        states[accounts[2].id] = state(remaining: 90)
        XCTAssertEqual(AccountSelection.rotating(provider: .codex, accounts: accounts, states: states,
            order: order, currentID: accounts[2].id, thresholdPercent: 95, now: now)?.id, accounts[2].id,
            "When every account is below the threshold, the freshest quota wins")
    }

    @MainActor
    func testRotationOrderThresholdAndManualNextPersist() throws {
        let root = try temporary()
        let manager = AccountManager(rootURL: root)
        let first = try manager.add(provider: .codex, label: "Work", emailHint: nil)
        let second = try manager.add(provider: .codex, label: "Personal", emailHint: nil)
        try manager.moveInRotation(second, offset: -1)
        try manager.setNext(second)
        try manager.setSwitchThreshold(25)

        let restored = AccountManager(rootURL: root)
        XCTAssertEqual(restored.rotationAccounts(for: .codex).map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.selectedAccount(for: .codex)?.id, second.id)
        XCTAssertEqual(restored.switchThresholdPercent, 25)
    }

    @MainActor
    func testAutomaticRotationPublishesTheExactAccountHandoff() async throws {
        let runner = SequencedQuotaRunner(outputs: [
            #"{"account":{"type":"chatgpt","email":"old@example.test"},"limits":{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300}}}}"#,
            #"{"account":{"type":"chatgpt","email":"new@example.test"},"limits":{"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":300}}}}"#
        ])
        let manager = AccountManager(rootURL: try temporary(), runner: runner,
            executable: { _ in URL(fileURLWithPath: "/fake/codex") })
        let old = try manager.add(provider: .codex, label: "Research", emailHint: nil)
        let new = try manager.add(provider: .codex, label: "Production", emailHint: nil)
        try manager.select(old)
        manager.automaticSelection = true

        await manager.refresh(old)
        XCTAssertNil(manager.automaticSwitch)
        await manager.refresh(new)
        manager.reconcileAutomaticSelection()

        let event = try XCTUnwrap(manager.automaticSwitch)
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.fromID, old.id)
        XCTAssertEqual(event.fromName, "Research")
        XCTAssertEqual(event.toID, new.id)
        XCTAssertEqual(event.toName, "Production")
        XCTAssertEqual(manager.selectedAccount(for: .codex)?.id, new.id)
    }

    func testQuotaParsingFreshnessAndAllCodexBuckets() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let status = Data(#"{"loggedIn":true,"email":"test@example.test","subscriptionType":"max"}"#.utf8)
        XCTAssertTrue(try AccountQuotas.claude(status: status, quota: nil).needsFirstUsage)
        let quota = Data(#"{"recordedAt":1799999900,"rate_limits":{"five_hour":{"used_percentage":20,"resets_at":1800001000},"seven_day":{"used_percentage":100,"resets_at":1800200000}}}"#.utf8)
        let claude = try AccountQuotas.claude(status: status, quota: quota, now: now)
        XCTAssertTrue(claude.isFresh(at: now)); XCTAssertEqual(claude.remainingPercent, 0)
        XCTAssertFalse(claude.isFresh(at: now.addingTimeInterval(301)))
        let codex = Data(#"{"account":{"type":"chatgpt","email":"test@example.test","planType":"plus"},"limits":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800001000},"secondary":{"usedPercent":60,"windowDurationMins":10080}},"review":{"primary":{"usedPercent":100}}}}}"#.utf8)
        let parsed = try AccountQuotas.codex(codex, now: now)
        XCTAssertEqual(parsed.windows.count, 3)
        XCTAssertEqual(parsed.windows.first?.usedFraction, 0.25)
        XCTAssertEqual(parsed.windows.map(\.label), [
            "All Codex models · 5h limit",
            "All Codex models · Weekly limit",
            "review · Session limit"
        ])
        XCTAssertEqual(parsed.remainingPercent, 0)
        XCTAssertFalse(try AccountQuotas.codex(Data(#"{"account":{"type":"apiKey"}}"#.utf8)).isConnected)
        XCTAssertNil(AccountQuotas.percentage(["used": true], key: "used"))
        XCTAssertEqual(AccountQuotas.percentage(["used": 150], key: "used"), 1)
        let blockedData = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimits":{"rateLimitReachedType":"workspaceCredits","primary":{"usedPercent":10,"windowDurationMins":15}}}}"#.utf8)
        let blocked = try AccountQuotas.codex(blockedData, now: now)
        XCTAssertNotNil(blocked.message)
        XCTAssertEqual(blocked.windows.first?.label, "All Codex models · 15 min limit")
        let candidate = ManagedAccount(id: UUID(), provider: .codex, label: "Blocked", createdAt: now)
        XCTAssertNil(AccountSelection.best(provider: .codex, accounts: [candidate], states: [candidate.id: blocked], now: now))
    }

    @MainActor
    func testFakeLoginFailureAndCancellationKeepLifecycleConsistent() async throws {
        let fake = FakeAccountRunner()
        let manager = AccountManager(rootURL: try temporary(), runner: fake, executable: { _ in URL(fileURLWithPath: "/fake/cli") })
        let account = try manager.add(provider: .codex, label: "Test", emailHint: nil)
        fake.failure = true
        await manager.connect(account)
        XCTAssertFalse(manager.state(for: account).isConnected)
        XCTAssertNil(manager.loginAccountID); XCTAssertTrue(manager.busyIDs.isEmpty)
        fake.failure = false; fake.waitForCancellation = true
        let task = Task { await manager.connect(account) }
        for _ in 0..<50 { if manager.loginAccountID != nil { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        manager.cancelLogin(); await task.value
        XCTAssertNil(manager.loginAccountID); XCTAssertTrue(manager.busyIDs.isEmpty)
        XCTAssertEqual(manager.notice, ManagedAccountError.cancelled.localizedDescription)
        fake.waitForCancellation = false
        await manager.connect(account)
        XCTAssertTrue(manager.state(for: account).isConnected)
        XCTAssertEqual(fake.commands.last?.environment["CODEX_HOME"], manager.configurationDirectory(for: account).path)
    }

    func testClaudeLoggedOutStatusExitIsNotAnOperationalFailure() async throws {
        let root = try temporary(), executable = root.appendingPathComponent("fake-cli")
        try AccountStorage.write(Data("#!/bin/sh\necho '{\"loggedIn\":false}'\nexit 1\n".utf8), to: executable, mode: 0o700)
        let runner = OfficialAccountProcess()
        let status = AccountCommand(executable: executable, arguments: ["auth", "status", "--json"], environment: [:], directory: root)
        let data = try await runner.run(status, cancellation: AccountCancellation())
        let state = try AccountQuotas.claude(status: data, quota: nil)
        XCTAssertFalse(state.isConnected)
        XCTAssertEqual(state.message, "Connect this account.")
        var login = status; login.arguments = ["auth", "login", "--claudeai"]
        do {
            _ = try await runner.run(login, cancellation: AccountCancellation())
            XCTFail("Nonzero login exits must still fail")
        } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.commandFailed(1).localizedDescription) }
        for value in ["true", "0", "null", "\"false\""] {
            try AccountStorage.write(Data("#!/bin/sh\necho '{\"loggedIn\":\(value)}'\nexit 1\n".utf8), to: executable, mode: 0o700)
            do {
                _ = try await runner.run(status, cancellation: AccountCancellation())
                XCTFail("Only an explicit JSON false can use exit 1")
            } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.commandFailed(1).localizedDescription) }
        }
    }

    func testRealFakeProcessRPCAndCancellation() async throws {
        let root = try temporary(), executable = root.appendingPathComponent("fake-cli")
        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) echo '{"id":1,"result":{}}' ;;
            *'"account/read"'*) echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"fake@example.test","planType":"plus"}}}' ;;
            *'"account/rateLimits/read"'*) echo '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":30,"windowDurationMins":300}}}}' ;;
          esac
        done
        """#
        try AccountStorage.write(Data(script.utf8), to: executable, mode: 0o700)
        let runner = OfficialAccountProcess()
        let command = AccountCommand(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], directory: root, timeout: 3, readsCodexAccount: true)
        let data = try await runner.run(command, cancellation: AccountCancellation())
        XCTAssertEqual(try AccountQuotas.codex(data).windows.first?.usedFraction, 0.3)
        let cancellation = AccountCancellation()
        let waiting = Task { try await runner.run(AccountCommand(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], environment: [:], directory: root), cancellation: cancellation) }
        try await Task.sleep(nanoseconds: 100_000_000); cancellation.cancel()
        do { _ = try await waiting.value; XCTFail("Cancellation must fail") } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
    }

    func testJXAStatusLineWritesOnlyWhitelistedQuotaPrivately() async throws {
        let root = try temporary(); try ClaudeAccountStatusLine.configure(profile: root)
        let input = root.appendingPathComponent("input.json")
        let data = Data(#"{"secret":"NEVER-PERSIST","transcript_path":"private","rate_limits":{"five_hour":{"used_percentage":23,"resets_at":1800001000,"token":"NEVER-PERSIST"},"seven_day":{"used_percentage":43,"resets_at":1800002000}}}"#.utf8)
        try AccountStorage.write(data, to: input)
        let script = root.appendingPathComponent("invoke")
        let command = "#!/bin/sh\nexec /usr/bin/osascript -l JavaScript \(AccountEnvironment.quote(root.appendingPathComponent("account-statusline.js").path)) \(AccountEnvironment.quote(root.path)) < \(AccountEnvironment.quote(input.path))\n"
        try AccountStorage.write(Data(command.utf8), to: script, mode: 0o700)
        _ = try await OfficialAccountProcess().run(AccountCommand(executable: script, arguments: [], environment: ["PATH": "/usr/bin:/bin"], directory: root), cancellation: AccountCancellation())
        let quota = root.appendingPathComponent("quota.json")
        let saved = try String(contentsOf: quota, encoding: .utf8)
        XCTAssertFalse(saved.contains("NEVER-PERSIST")); XCTAssertFalse(saved.contains("transcript"))
        XCTAssertTrue(saved.contains("23"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: quota.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor
    func testLaunchCommandExecutesChosenProfileInQuotedProject() async throws {
        let root = try temporary(), fake = FakeAccountRunner()
        let executable = root.appendingPathComponent("fake vendor")
        try AccountStorage.write(Data("#!/bin/sh\nprintf '%s|%s|%s' \"$CODEX_HOME\" \"${OPENAI_API_KEY-unset}\" \"$PWD\"\n".utf8), to: executable, mode: 0o700)
        var launcher: URL?
        let manager = AccountManager(rootURL: root.appendingPathComponent("accounts"), runner: fake,
                                     executable: { _ in executable }, openTerminal: { launcher = $0; return true })
        let account = try manager.add(provider: .codex, label: "Work", emailHint: nil)
        let project = root.appendingPathComponent("project's $(ignored) folder")
        try AccountStorage.privateDirectory(project)
        await manager.launch(account, project: project)
        let script = try XCTUnwrap(launcher)
        let data = try await OfficialAccountProcess().run(AccountCommand(executable: script, arguments: [],
            environment: ["OPENAI_API_KEY": "MUST-NOT-SURVIVE"], directory: root), cancellation: AccountCancellation())
        let result = String(decoding: data, as: UTF8.self)
        let fields = result.components(separatedBy: "|")
        XCTAssertEqual(fields.count, 3)
        XCTAssertEqual(fields[0], manager.configurationDirectory(for: account).path)
        XCTAssertEqual(fields[1], "unset")
        // /var and /private/var name the same macOS temporary directory.
        let actual = try FileManager.default.attributesOfItem(atPath: fields[2])
        let expected = try FileManager.default.attributesOfItem(atPath: project.path)
        XCTAssertEqual(actual[.systemFileNumber] as? NSNumber, expected[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(manager.selectedAccount(for: .codex)?.id, account.id)
    }

    func testTimeoutKillsOwnedDescendants() async throws {
        let root = try temporary(), script = root.appendingPathComponent("timeout.sh"), childFile = root.appendingPathComponent("child.pid")
        let source = "#!/bin/sh\n/bin/sleep 30 &\nprintf '%s' $! > \(AccountEnvironment.quote(childFile.path))\nwait\n"
        try AccountStorage.write(Data(source.utf8), to: script, mode: 0o700)
        do {
            // Allow macOS to start the fixture before exercising descendant
            // termination; cold process startup can exceed 300 ms.
            _ = try await OfficialAccountProcess().run(AccountCommand(executable: script, arguments: [], environment: [:], directory: root, timeout: 2), cancellation: AccountCancellation())
            XCTFail("Should time out")
        } catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.timedOut.localizedDescription) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
        // A killed orphan may briefly be a zombie before launchd reaps it.
        for _ in 0..<100 { if kill(pid, 0) != 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "Owned child must not survive the timeout")
    }
}

private final class FakeAccountRunner: AccountCommandRunning {
    var failure = false
    var waitForCancellation = false
    var commands: [AccountCommand] = []
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        commands.append(command)
        if failure { throw ManagedAccountError.commandFailed(1) }
        while waitForCancellation && !cancellation.isCancelled { try await Task.sleep(nanoseconds: 1_000_000) }
        if cancellation.isCancelled { throw ManagedAccountError.cancelled }
        return Data(#"{"account":{"type":"chatgpt","email":"test@example.test","planType":"plus"},"limits":{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300}}}}"#.utf8)
    }
}

private final class SequencedQuotaRunner: AccountCommandRunning {
    private var outputs: [Data]

    init(outputs: [String]) {
        self.outputs = outputs.map { Data($0.utf8) }
    }

    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        guard !outputs.isEmpty else { throw ManagedAccountError.commandFailed(1) }
        return outputs.removeFirst()
    }
}
