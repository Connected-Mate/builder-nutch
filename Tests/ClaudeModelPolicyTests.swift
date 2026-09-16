import XCTest
@testable import Codenotch

final class ClaudeModelPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ model: String? = nil, used: Double? = 0.1, blocked: Bool = false) -> LimitWindow {
        .init(id: model ?? "five_hour", label: model.map { "\($0) weekly limit" } ?? "5h limit",
              usedFraction: used, resetsAt: now.addingTimeInterval(3600), modelName: model, blocked: blocked)
    }

    private func state(_ windows: [LimitWindow]) -> ManagedAccountState {
        var value = ManagedAccountState(isConnected: true, windows: windows, refreshedAt: now)
        if windows.contains(where: { $0.isBlocked || ($0.usedFraction ?? 0) >= 1 }) {
            value.message = ClaudeAccountUsage.restriction(value, now: now)
        }
        return value
    }

    private func account(_ label: String) -> ManagedAccount {
        .init(id: UUID(), provider: .claude, label: label, createdAt: now)
    }

    func testRecognizesOnlyConclusiveFamilyNames() {
        for name in ["sonnet", "Claude Sonnet 4.6", "claude-sonnet-4-6", "claude-sonnet-4-20250514", "claude-3-5-sonnet-20241022", "sonnet[1m]", "Sonnet 4.6 (1M context)"] {
            XCTAssertEqual(ClaudeModelPolicy.family(for: name), .sonnet, name)
        }
        for name in ["", "unknown", "not-sonnet", "Sonnet and Opus", "opusplan", "sonnet-custom", "claude-sonnet-4/private", "Model Sonnet", "Sonnet; Haiku"] {
            XCTAssertNil(ClaudeModelPolicy.family(for: name), name)
        }
        XCTAssertEqual(ClaudeModelPolicy.family(for: "Fable"), .fable)
        XCTAssertEqual(ClaudeModelPolicy.family(for: "haiku-4-5[200k]"), .haiku)
    }

    func testProjectionRemovesOnlyOtherKnownFamiliesAndKeepsDetails() {
        let original = state([window(), window("Fable", used: 1), window("Sonnet", used: 0.2)])
        let result = ClaudeModelPolicy.project(original, model: "claude-sonnet-4-6", now: now)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertNil(result.message)
        XCTAssertEqual(result.remainingPercent, 80)
        XCTAssertEqual(original.windows.count, 3)
        XCTAssertNotNil(original.message)
        XCTAssertEqual(ClaudeModelPolicy.project(original, model: "unknown", now: now).windows.count, 3)
        XCTAssertNotNil(ClaudeModelPolicy.project(original, model: "Fable", now: now).message)
    }

    func testUnknownScopeAndUsageRemainBlocking() {
        for unknown in [window("Custom", used: 1), window("Fable", used: nil), window("Fable", used: .nan)] {
            let original = state([window(), unknown])
            let result = ClaudeModelPolicy.project(original, model: "Sonnet", now: now)
            XCTAssertEqual(result.windows.count, 2)
            let a = account("A")
            XCTAssertNil(ClaudeModelPolicy.fallbackChoice(preferredModel: "Sonnet", accounts: [a],
                states: [a.id: original], order: [a.id], now: now))
        }
    }

    func testProjectionNeverClearsUnrelatedFailuresOrSharedLocks() {
        var failure = state([window(), window("Fable", used: 1)])
        failure.message = "Unrelated service failure"
        XCTAssertEqual(ClaudeModelPolicy.project(failure, model: "Sonnet", now: now).message, failure.message)
        failure = state([window(), window("Fable", used: 1)])
        failure.usageCheckFailedAt = now
        XCTAssertNotNil(ClaudeModelPolicy.project(failure, model: "Sonnet", now: now).message)
        failure = state([window(), window("Fable", used: 1)])
        failure.refreshedAt = now.addingTimeInterval(-301)
        XCTAssertNotNil(ClaudeModelPolicy.project(failure, model: "Sonnet", now: now).message)
        for shared in [window(used: 1), window(blocked: true)] {
            let value = state([shared, window("Fable", used: 1)])
            XCTAssertNotNil(ClaudeModelPolicy.project(value, model: "Sonnet", now: now).message)
        }
    }

    func testProviderWideAndUnknownRestrictionsSurvive() {
        for scope: String? in [nil, "Custom", "Sonnet; Fable"] {
            var value = state([window(), window("Sonnet")])
            value.providerRestriction = .init(label: "Provider lock", modelName: scope, observedAt: now)
            XCTAssertNotNil(ClaudeModelPolicy.project(value, model: "Sonnet", now: now).providerRestriction)
        }
        var value = state([window(), window("Sonnet")])
        value.providerRestriction = .init(label: "Fable lock", modelName: "Fable", observedAt: now)
        value.message = ClaudeAccountUsage.restriction(value, now: now)
        let result = ClaudeModelPolicy.project(value, model: "Sonnet", now: now)
        XCTAssertNil(result.providerRestriction)
        XCTAssertNil(result.message)
    }

    func testPreferredModelMovesAccountBeforeAnyDowngrade() {
        let a = account("A"), b = account("B")
        let states = [a.id: state([window(), window("Fable", used: 1), window("Opus")]),
                      b.id: state([window(), window("Fable", used: 0.999), window("Opus")])]
        let choice = ClaudeModelPolicy.fallbackChoice(preferredModel: "claude-fable-5", accounts: [a, b],
            states: states, order: [a.id, b.id], currentID: a.id, now: now)
        XCTAssertEqual(choice?.accountID, b.id)
        XCTAssertEqual(choice?.model, "claude-fable-5")
        XCTAssertEqual(choice?.isFallback, false)
    }

    func testVerifiedFallbackUsesDowngradeOrderAndNeverUpgrades() {
        let a = account("A")
        var value = state([window(), window("Fable", used: 1), window("Opus", used: 0.9), window("Sonnet"), window("Haiku")])
        func choice(_ preferred: String) -> ClaudeModelPolicy.Choice? {
            ClaudeModelPolicy.fallbackChoice(preferredModel: preferred, accounts: [a], states: [a.id: value], order: [a.id], now: now)
        }
        XCTAssertEqual(choice("Fable")?.family, .opus)
        value = state([window(), window("Sonnet", used: 1), window("Opus"), window("Haiku")])
        XCTAssertEqual(choice("Sonnet")?.family, .haiku)
        value = state([window(), window("Haiku", used: 1), window("Opus")])
        XCTAssertNil(choice("Haiku"))
        XCTAssertNil(choice("Custom"))
    }

    func testFallbackRequiresExplicitSharedAndModelHeadroom() {
        let a = account("A")
        for windows in [[window(), window("Fable", used: 1)],
                        [window("Fable", used: 1), window("Opus")],
                        [window(used: 1), window("Fable", used: 1), window("Opus")],
                        [window(), window("Fable", used: 1), window("Opus", blocked: true)],
                        [window(), window("Fable", used: 1), window("Opus", used: nil)]] {
            XCTAssertNil(ClaudeModelPolicy.fallbackChoice(preferredModel: "Fable", accounts: [a],
                states: [a.id: state(windows)], order: [a.id], now: now))
        }
    }

    func testFallbackWaitsForFreshKnownIdleQueue() {
        let a = account("A"), b = account("B")
        let exhausted = state([window(), window("Fable", used: 1), window("Opus")])
        for condition in 0..<5 {
            var unproven = state([window(), window("Fable")])
            switch condition {
            case 0: unproven.refreshedAt = now.addingTimeInterval(-301)
            case 1: unproven.isBusy = true
            case 2: unproven.usageCheckFailedAt = now
            case 3: unproven.windows = []
            default: unproven.message = "Unrelated failure"
            }
            XCTAssertNil(ClaudeModelPolicy.fallbackChoice(preferredModel: "Fable", accounts: [a, b],
                states: [a.id: exhausted, b.id: unproven], order: [a.id, b.id], now: now), "condition \(condition)")
        }
    }
}
