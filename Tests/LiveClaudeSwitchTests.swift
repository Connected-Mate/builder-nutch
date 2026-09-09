import XCTest
import Foundation
@testable import Codenotch

/// Opt-in proof on the developer's own Mac: switches the real Claude Code login
/// through the production `AccountManager` path, exactly as the **Use account**
/// button does. It runs only when both variables are set, so an ordinary test
/// run never touches a real login:
///
///     TEST_RUNNER_CODENOTCH_LIVE_SWITCH=1 \
///     TEST_RUNNER_CODENOTCH_LIVE_SWITCH_ACCOUNT=<account UUID from accounts.json> \
///     xcodebuild ... test -only-testing:CodenotchTests/LiveClaudeSwitchTests
///
/// Quit Builder Nutch first so two processes do not persist the catalog at once.
@MainActor
final class LiveClaudeSwitchTests: XCTestCase {
    func testSwitchesTheMacLoginToTheRequestedAccount() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CODENOTCH_LIVE_SWITCH"] == "1",
              let raw = environment["CODENOTCH_LIVE_SWITCH_ACCOUNT"], let target = UUID(uuidString: raw) else {
            throw XCTSkip("Set CODENOTCH_LIVE_SWITCH=1 and CODENOTCH_LIVE_SWITCH_ACCOUNT=<uuid> to run this live proof.")
        }
        let manager = AccountManager()
        let account = try XCTUnwrap(manager.accounts.first { $0.id == target && $0.provider == .claude }, "Unknown Claude account")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent(".claude.json")
        func macEmail() throws -> String? {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]
            return (object?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
        }
        let before = try macEmail()
        await manager.launch(account, project: home)
        let notice = manager.notice ?? ""
        let state = manager.state(for: account)
        print("LIVE-SWITCH state: connected=\(state.isConnected) message=\(state.message ?? "-") requiresKeychainAccess=\(state.requiresKeychainAccess) notice=\(notice)")
        XCTAssertTrue(notice.contains("now uses \(account.label)"), "Switch did not complete: \(notice)")
        XCTAssertEqual(manager.systemClaudeAccountID, target)
        XCTAssertEqual(manager.selectedAccount(for: .claude)?.id, target)
        let after = try macEmail()
        XCTAssertNotEqual(before, after, "The Mac login identity did not change")
        // The cache marker tells running Claude sessions to reload their login.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/.credentials.json").path))
        await manager.shutdownAndWait()
    }
}
