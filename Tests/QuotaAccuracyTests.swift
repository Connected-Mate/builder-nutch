import XCTest
@testable import Codenotch

final class QuotaAccuracyTests: XCTestCase {
    @MainActor func testLowSessionUsageAndSpentModelRemainDifferentMeasurements() throws {
        let now = Date()
        let payload = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4},"seven_day":{"utilization":55},"model_scoped":[{"display_name":"Fable","utilization":100}]}}"#.utf8)
        let state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: payload, now: now)
        XCTAssertEqual(try XCTUnwrap(state.accountRemainingPercent), 45, accuracy: 0.001)
        XCTAssertEqual(state.accountBindingWindow?.id, "seven_day")
        XCTAssertEqual(state.primaryWindow?.id, "five_hour")
        XCTAssertEqual(try XCTUnwrap(state.primaryRemainingPercent), 96, accuracy: 0.001)
        XCTAssertEqual(state.remainingPercent, 0, "Model-agnostic rotation remains conservative")
        XCTAssertTrue(state.message?.contains("Fable") == true)
        XCTAssertTrue(state.message?.contains("choose another model") == true)
        let account = ManagedAccount(id: UUID(), provider: .claude, label: "Staff2 fixture", createdAt: now)
        XCTAssertEqual(AccountManager.headlineID(for: account, state: state), "five_hour")
    }

    func testModelLockBelowFullUsageNamesTheScopeWithoutInventingExhaustion() throws {
        let payload = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4},"model_scoped":[{"display_name":"Opus","utilization":5,"locked_reason":"restricted"}]}}"#.utf8)
        let state = try ClaudeAccountUsage.state(status: ManagedAccountState(isConnected: true), usage: payload)
        XCTAssertEqual(state.accountRemainingPercent, 96)
        XCTAssertTrue(state.windows.last?.isBlocked == true)
        XCTAssertTrue(state.message?.contains("Opus") == true)
        XCTAssertTrue(state.message?.contains("choose another model") == true)
        XCTAssertFalse(state.message?.contains("used up") == true)
    }

    func testFreshSuccessfulReadingClearsPollingFailureAndKeepsNearFullModelExact() throws {
        let now = Date()
        let previous = ManagedAccountState(isConnected: true, usageCheckFailedAt: now,
                                           usageCheckRetryAt: now.addingTimeInterval(3600))
        let payload = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4},"seven_day":{"utilization":55},"model_scoped":[{"display_name":"Fable","utilization":99.6}]}}"#.utf8)
        let state = try ClaudeAccountUsage.state(status: previous, usage: payload, now: now)
        XCTAssertTrue(state.isFresh(at: now))
        XCTAssertNil(state.usageCheckFailedAt)
        XCTAssertNil(state.usageCheckRetryAt)
        XCTAssertNil(state.message, "Rounding to 100% in a label must not create a vendor block")
        XCTAssertEqual(try XCTUnwrap(state.remainingPercent), 0.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(state.accountRemainingPercent), 45, accuracy: 0.001)
    }

    func testMissingSharedAllowanceNeverBecomesFullAccountAllowance() {
        let model = LimitWindow(id: "model", label: "Model", usedFraction: 0, modelName: "Model")
        XCTAssertNil(ManagedAccountState(windows: [model]).accountRemainingPercent)
        let unknown = LimitWindow(id: "weekly", label: "Weekly")
        XCTAssertNil(ManagedAccountState(windows: [model, unknown]).accountRemainingPercent)
        let known = LimitWindow(id: "session", label: "Session", usedFraction: 0.04)
        XCTAssertNil(ManagedAccountState(windows: [known, unknown]).accountRemainingPercent)
        XCTAssertNil(ManagedAccountState(windows: [known, unknown]).accountBindingWindow)
    }

    func testMissingPrimaryAllowanceNeverBorrowsWeeklyUsage() throws {
        let weekly = LimitWindow(id: "seven_day", label: "Weekly limit", usedFraction: 0.70)
        let state = ManagedAccountState(isConnected: true, windows: [weekly])
        XCTAssertNil(state.primaryWindow)
        XCTAssertNil(state.primaryUsedFraction)
        XCTAssertNil(state.primaryRemainingPercent)
        XCTAssertEqual(try XCTUnwrap(state.accountRemainingPercent), 30, accuracy: 0.001)
    }

    func testOtherDesktopProvidersKeepTheirDeclaredHeadline() {
        let included = LimitWindow(id: "included", label: "Included usage", usedFraction: 0.18)
        let cursor = ManagedAccountState(windows: [included,
            LimitWindow(id: "api", label: "API usage", usedFraction: 0.90)])
        XCTAssertEqual(cursor.headlineWindow(for: .cursor)?.id, "included")
        XCTAssertEqual(cursor.headlineRemainingPercent(for: .cursor), 82)

        let summary = LimitWindow(id: "primary", label: "Weekly limit", usedFraction: 0.30)
        let kimi = ManagedAccountState(windows: [summary,
            LimitWindow(id: "limit-0", label: "5h limit", usedFraction: 0.80)])
        XCTAssertEqual(kimi.headlineWindow(for: .kimi)?.id, "primary")
        XCTAssertEqual(kimi.headlineRemainingPercent(for: .kimi), 70)
        XCTAssertEqual(kimi.headlinePeriodText(for: .kimi), "Weekly")
    }

    @MainActor func testHeadlineUsesTheSameSessionMeasurementForClaudeAndCodex() {
        for provider in [AccountProvider.claude, .codex] {
            let account = ManagedAccount(id: UUID(), provider: provider, label: "Fixture", createdAt: Date())
            let shortID = provider == .claude ? "five_hour" : "primary"
            let longID = provider == .claude ? "seven_day" : "secondary"
            let short = LimitWindow(id: shortID, label: "5h", usedFraction: 0.04)
            let weekly = LimitWindow(id: longID, label: "Weekly", usedFraction: 0.55)
            let known = ManagedAccountState(isConnected: true, windows: [short, weekly])
            XCTAssertEqual(AccountManager.headlineID(for: account, state: known), shortID)
            let partial = ManagedAccountState(isConnected: true, windows: [short, LimitWindow(id: longID, label: "Weekly")])
            let headlineID = AccountManager.headlineID(for: account, state: partial)
            XCTAssertEqual(partial.windows.first { $0.id == headlineID }?.usedFraction, 0.04,
                           "An unknown weekly allowance must not hide the known session measurement")
            XCTAssertNil(partial.accountRemainingPercent)
            let missingSession = ManagedAccountState(isConnected: true, windows: [weekly])
            let missingID = AccountManager.headlineID(for: account, state: missingSession)
            XCTAssertNil(missingSession.windows.first { $0.id == missingID },
                         "A weekly allowance must not silently become the session headline")
        }
    }

    func testCodexSeparateScopeDoesNotConsumeSharedAllowance() throws {
        let payload = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":4}},"codex_spark":{"limitName":"Spark","primary":{"usedPercent":100}}}}}"#.utf8)
        let state = try AccountQuotas.codex(payload)
        XCTAssertEqual(state.accountRemainingPercent, 96)
        XCTAssertEqual(state.windows.last?.modelName, "Spark")
        XCTAssertEqual(state.remainingPercent, 0)
    }

    func testCodexModelEventCannotOverwriteOrFreshenSharedRollout() throws {
        let text = #"{"timestamp":"2026-09-14T10:00:00Z","rate_limits":{"limit_id":"codex","primary":{"used_percent":4}}}"# + "\n" +
            #"{"timestamp":"2026-09-14T11:00:00Z","rate_limits":{"limit_id":"codex_spark","primary":{"used_percent":100}}}"#
        XCTAssertEqual(try CodexUsage.windows(fromRollout: text).first?.usedFraction, 0.04)
        XCTAssertEqual(CodexUsage.recordedAt(inRollout: text), ISO8601DateFormatter().date(from: "2026-09-14T10:00:00Z"))
    }

    func testMalformedCodexNumbersAreNeverFreeAllowance() {
        for value in ["true", "-1", "null", "\"4\""] {
            XCTAssertThrowsError(try CodexUsage.windows(fromRollout:
                "{\"rate_limits\":{\"primary\":{\"used_percent\":\(value)}}}"))
        }
    }

    @MainActor func testPollingThrottlePreservesRealReadingTimeAndNeverClaimsAccountExhaustion() async throws {
        struct Reader: ClaudeAccountReading {
            func read(_ location: ClaudeCredentialLocation, cancellation: AccountCancellation) async throws -> ManagedAccountState {
                throw UsageProviderError.rateLimited(retryAfter: 3600)
            }
        }
        struct Runner: AccountCommandRunning {
            func run(_ command: AccountCommand, cancellation: AccountCancellation) async throws -> Data {
                XCTFail("A quiet usage check must not start the CLI")
                throw ManagedAccountError.unavailable
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quota-accuracy-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let manager = AccountManager(rootURL: root, runner: Runner(), executable: { _ in nil }, claudeReader: Reader())
        defer { manager.shutdown() }
        let account = try manager.add(provider: .claude, label: "Staff2 fixture", emailHint: nil)
        let recorded = Date().addingTimeInterval(-20)
        manager.applyState({ state in
            state.isConnected = true
            state.refreshedAt = recorded
            state.windows = [LimitWindow(id: "five_hour", label: "5h limit", usedFraction: 0.04),
                LimitWindow(id: "fable", label: "Fable weekly limit", usedFraction: 1, modelName: "Fable")]
        }, to: account.id)
        await manager.refresh(account)
        let state = manager.state(for: account)
        XCTAssertEqual(state.refreshedAt, recorded)
        XCTAssertNotNil(state.usageCheckFailedAt)
        XCTAssertGreaterThan(try XCTUnwrap(state.usageCheckRetryAt).timeIntervalSinceNow, 3500)
        XCTAssertFalse(state.isFresh())
        XCTAssertTrue(state.isConnected)
        XCTAssertEqual(state.accountRemainingPercent, 96)
        let snapshot = manager.snapshot(for: account)
        XCTAssertEqual(snapshot.status.staleSince, recorded)
        XCTAssertEqual(snapshot.usedFraction, 0.04)
        XCTAssertNil(snapshot.block, "A failed usage query does not prove a live usage block")
    }
}
