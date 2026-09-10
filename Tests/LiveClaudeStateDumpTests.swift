import XCTest
import Foundation
@testable import Codenotch

/// Opt-in, read-only look at what the real catalog reports on this Mac: per-account
/// windows, forecast, health and attention. Never switches anything (no refreshAll,
/// so no reconcile). Run with TEST_RUNNER_CODENOTCH_LIVE_DUMP=1.
@MainActor
final class LiveClaudeStateDumpTests: XCTestCase {
    func testDumpLiveState() async throws {
        guard ProcessInfo.processInfo.environment["CODENOTCH_LIVE_DUMP"] == "1" else {
            throw XCTSkip("Set CODENOTCH_LIVE_DUMP=1 to dump the live catalog state.")
        }
        let manager = AccountManager()
        for account in manager.accounts where account.provider == .claude {
            await manager.refresh(account)
            let state = manager.state(for: account)
            let windows = state.windows.map { window -> String in
                let used = window.usedFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
                let reset = window.resetsAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "-"
                return "\(window.label)=\(used) reset=\(reset)"
            }.joined(separator: " | ")
            // The verdict the rotation itself reaches, named. Without this a
            // healthy-looking account that the selector rejects is a dead end.
            let verdict = manager.unavailability(account) ?? "AVAILABLE"
            print("LIVE-DUMP \(account.label) [\(account.id.uuidString.prefix(8))] connected=\(state.isConnected) remaining=\(state.remainingPercent.map { String(format: "%.0f", $0) } ?? "?") fresh=\(state.isFresh()) verdict=\(verdict) msg=\(state.message ?? "-") :: \(windows)")
        }
        manager.updateHealth()
        print("LIVE-DUMP health: current=\(manager.health.currentName ?? "-") next=\(manager.health.nextName ?? "-") ready=\(manager.health.isSwitchReady) reason=\(manager.health.reason ?? "-")")
        print("LIVE-DUMP attention: \(manager.attention.map { "\($0.kind) \($0.title) — \($0.detail)" } ?? "none")")
        print("LIVE-DUMP lastAutomaticSwitch: \(manager.lastAutomaticSwitch.map { "\($0.fromName) -> \($0.toName) at \(DateFormatter.localizedString(from: $0.date, dateStyle: .short, timeStyle: .medium)) because \($0.reason)" } ?? "none")")
        print("LIVE-DUMP checksPaused=\(manager.usageChecksArePaused)")
        print("LIVE-DUMP systemClaude=\(manager.systemClaudeAccountID?.uuidString.prefix(8) ?? "-") selected=\(manager.selectedAccount(for: .claude)?.label ?? "-") threshold=\(manager.switchThresholdPercent) ahead=\(manager.switchAheadMinutes)")
        await manager.shutdownAndWait()
    }
}
