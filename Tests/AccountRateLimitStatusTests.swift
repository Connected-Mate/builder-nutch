import XCTest
@testable import Codenotch

final class AccountRateLimitStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPercentagesNeverInventRequestHeadroom() {
        let state = ManagedAccountState(isConnected: true,
            windows: [.init(id: "five_hour", label: "5h", usedFraction: 0.996)], refreshedAt: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .notReported)
        XCTAssertNil(state.rateLimitStatus(at: now).retryAt)
    }

    func testEndpointBackoffIsSeparateFromInferenceAndKeepsQuota() {
        let state = ManagedAccountState(isConnected: true,
            windows: [.init(id: "five_hour", label: "5h", usedFraction: 0.04)], refreshedAt: now,
            usageCheckFailedAt: now, usageCheckRetryAt: now.addingTimeInterval(60))
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .usageCheckPaused)
        XCTAssertEqual(state.primaryRemainingPercent, 96)
        XCTAssertEqual(state.rateLimitStatus(at: now.addingTimeInterval(60)).kind, .refreshRequired)
    }

    func testBothSpentWindowsWaitForTheLaterReset() {
        let state = ManagedAccountState(isConnected: true, windows: [
            .init(id: "five_hour", label: "5h", usedFraction: 1, resetsAt: now.addingTimeInterval(60)),
            .init(id: "seven_day", label: "Weekly", usedFraction: 1, resetsAt: now.addingTimeInterval(600))], refreshedAt: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .quotaExhausted)
        XCTAssertEqual(state.rateLimitStatus(at: now).retryAt, now.addingTimeInterval(600))
        XCTAssertEqual(state.rateLimitStatus(at: now.addingTimeInterval(60)).kind, .quotaExhausted)
    }

    func testOneUnknownResetCannotPromiseAccountResumption() {
        let state = ManagedAccountState(isConnected: true, windows: [
            .init(id: "five_hour", label: "5h", usedFraction: 1, resetsAt: now.addingTimeInterval(60)),
            .init(id: "seven_day", label: "Weekly", usedFraction: 1)], refreshedAt: now)
        XCTAssertNil(state.rateLimitStatus(at: now).retryAt)
    }

    func testModelRestrictionPreservesSharedAllowanceAndDerivedProvenance() {
        let state = ManagedAccountState(isConnected: true, windows: [
            .init(id: "five_hour", label: "5h", usedFraction: 0.04),
            .init(id: "model", label: "Model weekly", usedFraction: 1,
                  resetsAt: now.addingTimeInterval(60), derivedReset: true, modelName: "Model")], refreshedAt: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .modelRestricted)
        XCTAssertTrue(state.rateLimitStatus(at: now).isResetDerived)
        XCTAssertEqual(state.accountRemainingPercent, 96)
        XCTAssertEqual(state.rateLimitStatus(at: now.addingTimeInterval(60)).kind, .refreshRequired)
    }

    func testLockedBelowFullIsNotQuotaExhaustion() {
        let state = ManagedAccountState(isConnected: true,
            windows: [.init(id: "five_hour", label: "5h", usedFraction: 0.04, blocked: true)], refreshedAt: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertEqual(state.accountRemainingPercent, 96)
    }

    func testCodexRestrictionWithoutQuotaRetainsEvidenceAndExpires() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimits":{"rateLimitReachedType":"rate_limit_reached"}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertNotNil(state.providerRestriction)
        XCTAssertNil(state.rateLimitStatus(at: now).retryAt)
        XCTAssertEqual(state.rateLimitStatus(at: now.addingTimeInterval(301)).kind, .refreshRequired)
    }

    func testCodexQuotaRestrictionUsesOnlySpentWindowReset() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimits":{"rateLimitReachedType":"rate_limit_reached","primary":{"usedPercent":5,"resetsAt":1800000060},"secondary":{"usedPercent":100,"resetsAt":1800000600}}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .quotaExhausted)
        XCTAssertEqual(state.rateLimitStatus(at: now).retryAt, now.addingTimeInterval(600))
    }

    func testWorkspaceRestrictionNeverBorrowsQuotaReset() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimits":{"rateLimitReachedType":"workspace_owner_credits_depleted","primary":{"usedPercent":5,"resetsAt":1800000060}}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertNil(state.rateLimitStatus(at: now).retryAt)
        XCTAssertTrue(state.rateLimitStatus(at: now).affectedLabels.first?.contains("Workspace credits") == true)
    }

    func testMultipleCodexModelRestrictionsPreserveModelOnlyScope() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":4}},"model_a":{"limitName":"Model A","rateLimitReachedType":"rate_limit_reached"},"model_b":{"limitName":"Model B","rateLimitReachedType":"rate_limit_reached"}}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .modelRestricted)
        XCTAssertEqual(state.providerRestriction?.modelName, "Model A; Model B")
        XCTAssertEqual(state.accountRemainingPercent, 96)
        XCTAssertTrue(state.rateLimitStatus(at: now).affectedLabels.first?.contains("Model A") == true)
        XCTAssertTrue(state.rateLimitStatus(at: now).affectedLabels.first?.contains("Model B") == true)
    }

    func testMixedCodexRestrictionsRetainAccountScope() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":4},"rateLimitReachedType":"workspace_owner_credits_depleted"},"model_a":{"limitName":"Model A","rateLimitReachedType":"rate_limit_reached"}}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertNil(state.providerRestriction?.modelName)
    }

    func testPassedQuotaCannotHideFreshWorkspaceRestriction() throws {
        let data = Data(#"{"account":{"type":"chatgpt"},"limits":{"rateLimits":{"rateLimitReachedType":"workspace_owner_credits_depleted","primary":{"usedPercent":100,"resetsAt":1799999940}}}}"#.utf8)
        let state = try AccountQuotas.codex(data, now: now)
        let status = state.rateLimitStatus(at: now)
        XCTAssertEqual(status.kind, .providerRestricted)
        XCTAssertNil(status.retryAt)
        XCTAssertEqual(status.observedAt, now)
        XCTAssertTrue(status.affectedLabels.first?.contains("Workspace credits") == true)
    }

    func testPassedSharedQuotaCannotHideActiveModelRestriction() {
        let state = ManagedAccountState(isConnected: true, windows: [
            .init(id: "five_hour", label: "5h", usedFraction: 1, resetsAt: now.addingTimeInterval(-60)),
            .init(id: "model", label: "Model weekly", usedFraction: 1,
                  resetsAt: now.addingTimeInterval(600), modelName: "Model")], refreshedAt: now)
        let status = state.rateLimitStatus(at: now)
        XCTAssertEqual(status.kind, .modelRestricted)
        XCTAssertEqual(status.retryAt, now.addingTimeInterval(600))
        XCTAssertEqual(status.affectedLabels, ["Model weekly"])
    }

    func testFreshModelQuotaDoesNotRefreshOldWorkspaceEvidence() {
        let state = ManagedAccountState(isConnected: true, windows: [
            .init(id: "model", label: "Model weekly", usedFraction: 1,
                  resetsAt: now.addingTimeInterval(600), modelName: "Model")], refreshedAt: now,
            providerRestriction: .init(label: "Workspace", observedAt: now.addingTimeInterval(-301)))
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .modelRestricted)
        XCTAssertEqual(state.rateLimitStatus(at: now).affectedLabels, ["Model weekly"])
    }

    func testClaudeRestrictionWithoutWindowsRemainsVisible() throws {
        let data = Data(#"{"rate_limits_available":true,"rate_limits":{"future_scope":{"locked_reason":"restricted"}}}"#.utf8)
        let state = try ClaudeAccountUsage.state(status: .init(isConnected: true), usage: data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertNotNil(state.message)
    }

    func testUnknownClaudeAccountLockCannotMasqueradeAsOnlyAModelLimit() throws {
        let data = Data(#"{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":4},"model_scoped":[{"display_name":"Model","utilization":100}],"future_scope":{"locked_reason":"restricted"}}}"#.utf8)
        let state = try ClaudeAccountUsage.state(status: .init(isConnected: true), usage: data, now: now)
        XCTAssertEqual(state.rateLimitStatus(at: now).kind, .providerRestricted)
        XCTAssertNil(state.rateLimitStatus(at: now).retryAt)
    }

    func testCustomRestrictionWithoutQuotaIsNeverAZeroPercentMeasurement() throws {
        var assistant = try CustomAssistantConfiguration.validated(name: "Fixture", website: "https://example.com")
        assistant.usage = CustomAssistantUsage(limits: [], observedAt: now, source: "Authorized inference response",
            rateLimit: .init(kind: .concurrencyLimited, scope: "Model A", retryAt: now.addingTimeInterval(60)))
        try assistant.usage?.validate(now: now)
        let snapshot = assistant.snapshot(now: now)
        XCTAssertNil(snapshot.usedFraction)
        XCTAssertNotNil(snapshot.block)
        XCTAssertTrue(snapshot.block?.reason.contains("Model A") == true)
        XCTAssertNil(assistant.snapshot(now: now.addingTimeInterval(60)).block)
        XCTAssertTrue(assistant.snapshot(now: now.addingTimeInterval(60)).status.isStale)
    }

    func testCustomRateLimitRejectsInventedKindsAndPassedRetry() throws {
        let usage = CustomAssistantUsage(limits: [], observedAt: now, source: "Response",
            rateLimit: .init(kind: .rateLimited, scope: "Account", retryAt: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try usage.validate(now: now))
        let raw = Data(#"{"limits":[],"observedAt":0,"source":"Response","rateLimit":{"kind":"unlimited","scope":"Account"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CustomAssistantUsage.self, from: raw))
    }

    func testMCPRestrictionReportRoundTripsAndSuccessfulUsageClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rate-limit-mcp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CustomAssistantRepository(root: root)
        let assistant = try repository.configure(id: nil, name: "Fixture", website: "https://example.com")
        let server = CustomAssistantMCPServer(repository: repository)
        func request(_ method: String, _ params: [String: Any], id: Int? = 1) throws -> [String: Any]? {
            var request: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
            if let id { request["id"] = id }
            guard let data = server.handle(try JSONSerialization.data(withJSONObject: request)) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        _ = try request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "Fixture", "version": "1"]])
        _ = try request("notifications/initialized", [:], id: nil)
        var args: [String: Any] = ["id": assistant.id.uuidString, "limits": [],
            "observedAt": ISO8601DateFormatter().string(from: Date()), "source": "Authorized inference response",
            "rateLimit": ["kind": "rateLimited", "scope": "Model A"]]
        let reported = try request("tools/call", ["name": "report_usage", "arguments": args])
        XCTAssertEqual((reported?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(try repository.list().first?.usage?.rateLimit?.scope, "Model A")
        XCTAssertNil(try repository.list().first?.usage?.rateLimit?.retryAt)
        args["rateLimit"] = ["kind": "rateLimited", "scope": "Model A", "token": "REJECT-ME"]
        let rejected = try request("tools/call", ["name": "report_usage", "arguments": args])
        XCTAssertEqual((rejected?["result"] as? [String: Any])?["isError"] as? Bool, true)
        args.removeValue(forKey: "rateLimit")
        args["limits"] = [["label": "Session", "usedPercent": 12]]
        let cleared = try request("tools/call", ["name": "report_usage", "arguments": args])
        XCTAssertEqual((cleared?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertNil(try repository.list().first?.usage?.rateLimit)
    }
}
