import XCTest
@testable import Codenotch

final class ClaudeAccountUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-\(UUID().uuidString)")
        try AccountStorage.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func response(_ id: String, _ payload: [String: Any] = [:], success: Bool = true) throws -> Data {
        try data(["type": "control_response", "response": ["request_id": id, "subtype": success ? "success" : "error", "response": payload]])
    }

    func testReadOnlyProtocolRequiresInitializationAndWhitelistsResult() throws {
        var rpc = ClaudeUsageControlProtocol()
        XCTAssertEqual((rpc.initialize["request"] as? [String: Any])?["subtype"] as? String, "initialize")
        if case .none = try rpc.receive(response("builder-nutch-usage")) {} else { XCTFail("Ignore premature result") }
        if case .send(let request) = try rpc.receive(response("builder-nutch-init")) {
            let content = try XCTUnwrap(request["request"] as? [String: Any])
            XCTAssertEqual(content["subtype"] as? String, "get_usage")
            XCTAssertEqual(content["skip_behaviors"] as? Bool, true)
            XCTAssertNil(content["prompt"])
        } else { XCTFail("Usage must follow init") }
        if case .none = try rpc.receive(response("builder-nutch-init")) {} else { XCTFail("No duplicate requests") }
        if case .complete(let payload) = try rpc.receive(response("builder-nutch-usage", ["rate_limits_available": false, "session": ["private": 1], "behaviors": ["private": 2]])) {
            XCTAssertEqual(Set(payload.keys), ["rate_limits_available"])
        } else { XCTFail("Expected result") }
        var failed = ClaudeUsageControlProtocol()
        XCTAssertThrowsError(try failed.receive(response("builder-nutch-init", success: false)))
        _ = try failed.receive(response("builder-nutch-init"))
        XCTAssertThrowsError(try failed.receive(response("builder-nutch-usage", success: false)))
    }

    func testOfficialWindowsAndScopedLimitsBlockAutomaticSelection() throws {
        let usage = try data(["subscription_type": "max", "rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": 7, "resets_at": "2027-01-16T15:00:00Z"],
            "seven_day": ["utilization": 21, "resets_at": "2027-01-20T15:00:00Z"],
            "model_scoped": [["display_name": "Fable", "utilization": 100, "resets_at": "2027-01-20T15:00:00Z"]],
            "limits": [["kind": "session", "percent": 7, "severity": "normal", "is_active": false, "resets_at": "2027-01-16T15:00:00Z"]],
            "extra_usage": ["is_enabled": true, "utilization": 0]]])
        let state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true, email: "fixture@test.invalid"), usage: usage, now: now)
        XCTAssertEqual(state.windows.count, 3)
        XCTAssertEqual(state.windows.first?.usedFraction, 0.07)
        XCTAssertEqual(state.remainingPercent, 0)
        XCTAssertEqual(state.email, "fixture@test.invalid")
        XCTAssertEqual(state.plan, "max")
        let account = ManagedAccount(id: UUID(), provider: .claude, label: "Fixture", createdAt: now)
        XCTAssertNil(AccountSelection.best(provider: .claude, accounts: [account], states: [account.id: state], now: now))
    }

    func testVendorLocksOverrideAvailableQuotaInEverySubscriptionBucket() throws {
        let account = ManagedAccount(id: UUID(), provider: .claude, label: "Locked fixture", createdAt: now)
        for bucket: [String: Any] in [
            ["five_hour": ["utilization": 0, "locked_reason": "subscription_restricted"]],
            ["model_scoped": [["display_name": "Model", "utilization": 5, "locked_reason": "restricted"]]],
            ["limits": [["kind": "session", "percent": 5, "severity": "normal", "locked_reason": "restricted"]]],
            ["future_bucket": ["utilization": 1, "locked_reason": true]]
        ] {
            let state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: data(["rate_limits_available": true, "rate_limits": bucket]), now: now)
            XCTAssertNotNil(state.message)
            XCTAssertNil(AccountSelection.best(provider: .claude, accounts: [account], states: [account.id: state], now: now))
        }
        let available = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: data(["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": 0, "locked_reason": NSNull()], "extra_usage": ["locked_reason": "disabled"]]]), now: now)
        XCTAssertNil(available.message)
        XCTAssertEqual(AccountSelection.best(provider: .claude, accounts: [account], states: [account.id: available], now: now)?.id, account.id)
    }

    func testUnavailableUnknownAndMalformedNeverBecomeFreeAllowance() throws {
        let status = ManagedAccountState(isConnected: true)
        for object: [String: Any] in [
            ["rate_limits_available": false, "rate_limits": NSNull()],
            ["rate_limits_available": true, "rate_limits": NSNull()],
            ["rate_limits_available": true, "rate_limits": [:]]] {
            let state = try ClaudeAccountUsage.state(status: status, usage: data(object), now: now)
            XCTAssertNil(state.refreshedAt); XCTAssertNil(state.remainingPercent); XCTAssertNotNil(state.message)
        }
        for bad: Any in [true, -1, "7"] {
            XCTAssertThrowsError(try ClaudeAccountUsage.state(status: status, usage: data(["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": bad]]]), now: now))
        }
        let unknown = try ClaudeAccountUsage.state(status: status, usage: data(["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": NSNull()]]]), now: now)
        XCTAssertNil(unknown.remainingPercent)
        XCTAssertNil(unknown.refreshedAt)
        XCTAssertThrowsError(try ClaudeAccountUsage.state(status: status, usage: data(["rate_limits_available": 1]), now: now))
        let blocked = try ClaudeAccountUsage.state(status: status, usage: data(["rate_limits_available": true, "rate_limits": ["limits": [["kind": "workspace", "severity": "blocked", "percent": 1]]]]), now: now)
        XCTAssertNotNil(blocked.message)
        let newBucket = try ClaudeAccountUsage.state(status: status, usage: data(["rate_limits_available": true, "rate_limits": ["future_bucket": ["utilization": 100]]]), now: now)
        XCTAssertEqual(newBucket.remainingPercent, 0)
    }

    func testRealProcessSendsOnlyControlsAndHandlesImmediateExit() async throws {
        let root = try temporary(), script = root.appendingPathComponent("fake-cli")
        let source = #"""
        #!/bin/sh
        IFS= read -r init
        case "$init" in *'"initialize"'*) ;; *) exit 5 ;; esac
        echo '{"type":"control_response","response":{"request_id":"builder-nutch-init","subtype":"success","response":{}}}'
        IFS= read -r usage
        case "$usage" in *'"skip_behaviors":true'*'"get_usage"'*|*'"get_usage"'*'"skip_behaviors":true'*) ;; *) exit 6 ;; esac
        echo '{"type":"control_response","response":{"request_id":"builder-nutch-usage","subtype":"success","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":7}}}}}'
        exit 0
        """#
        try AccountStorage.write(Data(source.utf8), to: script, mode: 0o700)
        let command = ClaudeAccountUsage.command(executable: script, profile: root, environment: [:])
        XCTAssertEqual(command.environment["CLAUDE_CODE_SAFE_MODE"], "1")
        XCTAssertTrue(command.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(command.arguments.contains("--strict-mcp-config"))
        let value = try await OfficialAccountProcess().run(command, cancellation: AccountCancellation())
        XCTAssertEqual(try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: value).windows.first?.usedFraction, 0.07)
    }

    @MainActor
    func testManagerGetsUsageBeforeFirstSessionAndFallsBackForOlderCLI() async throws {
        let root = try temporary(), runner = ClaudeUsageFixtureRunner()
        let manager = AccountManager(rootURL: root, runner: runner, executable: { _ in URL(fileURLWithPath: "/fake/claude") })
        let account = try manager.add(provider: .claude, label: "Before first use", emailHint: nil)
        await manager.refresh(account)
        XCTAssertEqual(manager.state(for: account).windows.first?.usedFraction, 0.07)
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertTrue(runner.commands.last?.readsClaudeUsage == true)
        XCTAssertEqual(manager.state(for: account).email, "fixture@example.test")
        runner.olderCLI = true
        let profile = manager.configurationDirectory(for: account)
        let quota = try data(["recordedAt": Date().timeIntervalSince1970,
                              "rate_limits": ["five_hour": ["used_percentage": 11]]])
        try AccountStorage.write(quota, to: profile.appendingPathComponent("quota.json"))
        await manager.refresh(account)
        XCTAssertEqual(manager.state(for: account).windows.first?.usedFraction, 0.11)
        XCTAssertNil(manager.state(for: account).refreshedAt)
        XCTAssertNotNil(manager.state(for: account).message)
        XCTAssertTrue(manager.state(for: account).isConnected)
    }

    func testClaudeControlTimeoutAndCancellation() async throws {
        let root = try temporary(), script = root.appendingPathComponent("waiting-cli")
        try AccountStorage.write(Data("#!/bin/sh\nIFS= read -r line\nexec /bin/sleep 20\n".utf8), to: script, mode: 0o700)
        var command = ClaudeAccountUsage.command(executable: script, profile: root, environment: [:]); command.timeout = 0.25
        do { _ = try await OfficialAccountProcess().run(command, cancellation: AccountCancellation()); XCTFail("Must time out") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.timedOut.localizedDescription) }
        command.timeout = 10
        let cancellation = AccountCancellation(), waitingCommand = command
        let task = Task { try await OfficialAccountProcess().run(waitingCommand, cancellation: cancellation) }
        try await Task.sleep(nanoseconds: 100_000_000); cancellation.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") }
        catch { XCTAssertEqual(error.localizedDescription, ManagedAccountError.cancelled.localizedDescription) }
    }
}

private final class ClaudeUsageFixtureRunner: AccountCommandRunning {
    var commands: [AccountCommand] = []
    var olderCLI = false
    func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
        commands.append(command)
        if command.readsClaudeUsage {
            if olderCLI { throw ManagedAccountError.invalidResponse }
            return Data(#"{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":7},"seven_day":{"utilization":21}}}"#.utf8)
        }
        return Data(#"{"loggedIn":true,"authMethod":"claude.ai","email":"fixture@example.test","subscriptionType":"max"}"#.utf8)
    }
}
